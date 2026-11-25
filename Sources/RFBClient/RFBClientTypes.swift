import Foundation
import RFBBase

/// Everything `RFBClient` needs to connect. Value type; safe to pass across tasks.
public struct RFBClientConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var credential: RFBCredential
    /// ClientInit shared flag. true = leave other viewers connected. Default true.
    public var shared: Bool
    /// Security handlers in preference order; the first one whose type the server offers and which
    /// `canHandle` the credential is used.
    public var securityHandlers: [any SecurityHandler]
    /// Creates the per-connection decoders; their order is the SetEncodings preference order.
    public var decoderFactory: RectDecoderFactory
    /// Called with the server's public key for key-based schemes (type 33). nil = accept any key.
    public var hostKeyVerifier: (@Sendable (Data) async -> Bool)?
    /// Tight JPEG quality 0...9 (advertised only when a Tight decoder is present). nil = do not advertise.
    public var jpegQuality: Int?
    /// Compression level 0...9 (advertised only when a Tight decoder is present). nil = do not advertise.
    public var compressionLevel: Int?
    /// Advertise the Cursor pseudo-encoding (-239) so the server sends its cursor image. Default true.
    public var requestRemoteCursor: Bool
    /// TCP connect timeout in seconds. Default 10. (Not applied to injected streams.)
    public var connectTimeout: TimeInterval

    public init(host: String,
                port: UInt16 = 5900,
                credential: RFBCredential,
                shared: Bool = true,
                securityHandlers: [any SecurityHandler],
                decoderFactory: @escaping RectDecoderFactory,
                hostKeyVerifier: (@Sendable (Data) async -> Bool)? = nil,
                jpegQuality: Int? = 6,
                compressionLevel: Int? = 6,
                requestRemoteCursor: Bool = true,
                connectTimeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.credential = credential
        self.shared = shared
        self.securityHandlers = securityHandlers
        self.decoderFactory = decoderFactory
        self.hostKeyVerifier = hostKeyVerifier
        self.jpegQuality = jpegQuality
        self.compressionLevel = compressionLevel
        self.requestRemoteCursor = requestRemoteCursor
        self.connectTimeout = connectTimeout
    }
}

/// Things that happen on a connected session, delivered on `RFBClient.events`.
/// `.closed` is always the last event, delivered exactly once.
public enum RFBEvent: Sendable, Equatable {
    /// One event per FramebufferUpdate message, after all its rectangles were decoded into the
    /// framebuffer. Contains the real (non-pseudo) rectangles; may be empty (e.g. cursor-only update).
    case framebufferUpdated([RFBRect])
    /// DesktopSize pseudo-encoding: the framebuffer was reallocated (contents black until redrawn).
    case desktopResized(width: Int, height: Int)
    /// Cursor pseudo-encoding: new remote cursor image (width 0 / height 0 = invisible cursor).
    case cursorChanged(RFBCursor)
    case bell
    /// ServerCutText (Latin-1 decoded).
    case clipboard(String)
    /// The session ended. nil = closed by us (`disconnect()` or task cancellation).
    case closed(RFBError?)
}

/// Counters for diagnostics (`rfbprobe`, HUD).
public struct RFBStatistics: Sendable, Equatable {
    /// Bytes read from the transport, including the handshake.
    public var bytesReceived: Int = 0
    /// Bytes written to the transport, including the handshake.
    public var bytesSent: Int = 0
    /// FramebufferUpdate messages fully processed.
    public var updates: Int = 0
    /// Rectangles processed (real and pseudo).
    public var rects: Int = 0
    /// Rectangles per encoding number (pseudo-encodings included, with their negative numbers).
    public var rectsByEncoding: [Int32: Int] = [:]
    /// When `connect()` was called.
    public var connectStartedAt: Date?
    /// When ServerInit was received.
    public var serverInitAt: Date?
    /// When the first FramebufferUpdate (the answer to the initial full request) was fully decoded.
    public var firstUpdateAt: Date?

    public init() {}
}
