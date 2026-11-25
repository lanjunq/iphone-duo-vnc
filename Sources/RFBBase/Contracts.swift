import Foundation

// MARK: - Rectangle decoders

/// Decodes one real (non-pseudo) encoding. One instance per connection: decoders may keep state that
/// spans rectangles (zlib streams in Zlib/ZRLE/Tight MUST persist for the life of the connection).
///
/// Contract:
/// - Called after the client has read the rectangle header (x, y, w, h, encoding).
/// - Must consume exactly the bytes of this rectangle's payload from `reader`, no more, no less.
/// - Pixel data on the wire is always in `PixelFormat.bgrx8888` (see its doc comment for TPIXEL/CPIXEL).
/// - Writes the result into `framebuffer` (which is at least as large as the rect; out-of-bounds throws).
/// - Throws `RFBError.decodeFailed` / `.protocolViolation` on malformed data; never crashes on bad input.
public protocol RectDecoder: AnyObject {
    var encoding: Int32 { get }
    func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws
}

/// Creates the per-connection decoder set, in the client's order of preference (most preferred first).
/// The client advertises exactly these encodings (plus the pseudo-encodings it handles itself).
public typealias RectDecoderFactory = @Sendable () -> [any RectDecoder]

// MARK: - Security

/// Extra inputs for a security handshake.
public struct SecurityContext: Sendable {
    /// Called with the server's public key (DER, as sent by the server) for key-based schemes (type 33).
    /// Return false to abort with `RFBError.hostKeyRejected`. nil = accept any key.
    public var hostKeyVerifier: (@Sendable (_ publicKeyDER: Data) async -> Bool)?
    /// The protocol version line the SERVER sent, without the trailing newline, e.g. "RFB 003.889".
    public var serverVersion: String

    public init(serverVersion: String, hostKeyVerifier: (@Sendable (_ publicKeyDER: Data) async -> Bool)? = nil) {
        self.serverVersion = serverVersion
        self.hostKeyVerifier = hostKeyVerifier
    }
}

public enum SecurityOutcome: Sendable, Equatable {
    /// The handler finished its type-specific exchange; the client must now read the standard
    /// 4-byte SecurityResult (0 = OK; otherwise failed, with a reason string in RFB 3.8).
    case readSecurityResult
    /// The handler already consumed whatever result the scheme sends; go straight to ClientInit.
    case completed
}

/// One RFB security type. Stateless and reusable across connections.
///
/// Contract: on RFB 3.7/3.8 the client calls `selectAndAuthenticate`, which writes the 1-byte
/// security-type selection (coalesced with the handler's first message for
/// `CoalescedSelectionSecurityHandler`s) and then runs the exchange. On RFB 3.3 the server chooses
/// the type, no selection byte is sent, and the client calls `authenticate` directly.
/// Handlers must therefore not assume anything about how the selection byte was sent.
/// The handler performs the type-specific exchange using `reader` for input and `stream.write` for
/// output, and must not read past its own messages.
/// On bad credentials detected inside the exchange, throw `RFBError.authenticationFailed`.
public protocol SecurityHandler: Sendable {
    var securityType: UInt8 { get }
    /// Whether this handler can use the given credential (e.g. VNC auth needs `.vncPassword`).
    func canHandle(_ credential: RFBCredential) -> Bool
    func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                      context: SecurityContext) async throws -> SecurityOutcome
}

/// A security handler whose first client message must travel in the SAME write as the 1-byte
/// security-type selection. macOS Screen Sharing (type 33) closes the connection when the selection
/// byte and the key request arrive in separate segments, even 1 ms apart.
public protocol CoalescedSelectionSecurityHandler: SecurityHandler {
    /// Bytes to append to the selection byte in the same write. Throws before anything is sent if the
    /// credential is unusable.
    func selectionPayload(for credential: RFBCredential) throws -> Data
    /// The rest of the exchange, after `[securityType] + selectionPayload(for:)` was written.
    func authenticateAfterSelectionPayload(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                                           context: SecurityContext) async throws -> SecurityOutcome
}

public extension SecurityHandler {
    /// Writes the selection and performs the exchange the way the server needs it: one write of
    /// `[securityType] + payload` for `CoalescedSelectionSecurityHandler`s, otherwise the bare selection
    /// byte followed by `authenticate`. Clients use this instead of writing the selection themselves.
    func selectAndAuthenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                               context: SecurityContext) async throws -> SecurityOutcome {
        if let h = self as? CoalescedSelectionSecurityHandler {
            var first = Data([securityType])
            first.append(try h.selectionPayload(for: credential))
            try await stream.write(first)
            return try await h.authenticateAfterSelectionPayload(reader: reader, stream: stream,
                                                                 credential: credential, context: context)
        }
        try await stream.write(Data([securityType]))
        return try await authenticate(reader: reader, stream: stream, credential: credential, context: context)
    }
}
