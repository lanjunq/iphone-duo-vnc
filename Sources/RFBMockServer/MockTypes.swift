import Foundation
import RFBBase

/// Security the mock server requires.
public enum MockSecurity: Sendable, Equatable {
    /// Security type 1 (None).
    case none
    /// Security type 2 (classic VNC authentication) with a real DES challenge/response check.
    /// Only the first 8 UTF-8 bytes of the password are significant (as in every VNC server).
    case vncPassword(String)

    /// The RFB security type number.
    public var securityType: UInt8 {
        switch self {
        case .none: return 1
        case .vncPassword: return 2
        }
    }
}

/// Configuration of a `MockRFBServer`.
public struct MockServerConfiguration: Sendable {
    /// Initial framebuffer width in pixels.
    public var width: Int
    /// Initial framebuffer height in pixels.
    public var height: Int
    /// Desktop name sent in ServerInit.
    public var desktopName: String
    /// The 12-byte protocol version line the server sends, e.g. `"RFB 003.008\n"` (default) or
    /// `"RFB 003.889\n"` (what macOS sends) or `"RFB 003.003\n"`. Invalid values fall back to 003.008.
    public var versionLine: String
    /// The security the server actually implements.
    public var security: MockSecurity
    /// Security types to advertise in RFB 3.7+ (default: just `security.securityType`). Lets tests mimic
    /// macOS (`[30, 33, 36, 2, 35]`); selecting a type other than `security.securityType` fails the
    /// handshake with a SecurityResult failure.
    public var advertisedSecurityTypes: [UInt8]?
    /// Real encodings the server is willing to use. For each update it uses the first encoding in the
    /// client's SetEncodings list that is also in this set (Raw if none). CopyRect (1) is only used by the
    /// `copyRect(fromX:fromY:to:)` hook. Supported values: raw, copyRect, hextile, zlib, tight, zrle.
    public var supportedEncodings: Set<Int32>
    /// When true and the client advertised LastRect (-224), updates are sent with a rectangle count of
    /// 0xFFFF and terminated by a LastRect pseudo-rectangle.
    public var useLastRect: Bool
    /// Creates the scene for each connection, given the initial width and height.
    public var sceneFactory: @Sendable (_ width: Int, _ height: Int) -> any MockScene
    /// Maximum number of entries kept in `receivedEvents` / `sentUpdates` (oldest dropped). 0 = record nothing.
    public var eventLogLimit: Int

    public init(width: Int = 1280, height: Int = 800, desktopName: String = "Duo VNC Mock",
                versionLine: String = "RFB 003.008\n", security: MockSecurity = .none,
                advertisedSecurityTypes: [UInt8]? = nil,
                supportedEncodings: Set<Int32> = MockServerConfiguration.allEncodings,
                useLastRect: Bool = false,
                eventLogLimit: Int = 10_000,
                sceneFactory: @escaping @Sendable (_ width: Int, _ height: Int) -> any MockScene = { _, _ in TestPatternScene() }) {
        self.width = width
        self.height = height
        self.desktopName = desktopName
        self.versionLine = versionLine
        self.security = security
        self.advertisedSecurityTypes = advertisedSecurityTypes
        self.supportedEncodings = supportedEncodings
        self.useLastRect = useLastRect
        self.eventLogLimit = eventLogLimit
        self.sceneFactory = sceneFactory
    }

    /// Every real encoding the mock can produce.
    public static let allEncodings: Set<Int32> = [RFBEncoding.raw, RFBEncoding.copyRect, RFBEncoding.hextile,
                                                  RFBEncoding.zlib, RFBEncoding.tight, RFBEncoding.zrle]

    /// A configuration for the app's offline demo mode: 3840x2160 `DemoDesktopScene`, no auth,
    /// macOS-like version line, nothing recorded.
    public static func demo(width: Int = 3840, height: Int = 2160) -> MockServerConfiguration {
        MockServerConfiguration(width: width, height: height, desktopName: "演示 Mac",
                                versionLine: "RFB 003.889\n", security: .none, eventLogLimit: 0,
                                sceneFactory: { w, h in DemoDesktopScene(width: w, height: h) })
    }
}

/// Something the server received from a client (for test assertions). Passwords are never recorded.
public enum MockEvent: Sendable, Equatable {
    /// The client's version line without the trailing newline, e.g. "RFB 003.008".
    case clientVersion(String)
    case securitySelected(UInt8)
    case authentication(succeeded: Bool)
    case clientInit(shared: Bool)
    case setPixelFormat(PixelFormat)
    case setEncodings([Int32])
    case updateRequest(incremental: Bool, rect: RFBRect)
    case pointer(x: Int, y: Int, buttons: RFBButtonMask)
    case key(keysym: UInt32, down: Bool)
    /// ClientCutText, decoded as UTF-8 when valid, else ISO 8859-1 (the RFC encoding).
    case cutText(String)
    /// The connection ended; the reason is nil for a clean EOF.
    case disconnected(String?)
}

/// One rectangle of a sent FramebufferUpdate.
public struct MockSentRect: Sendable, Equatable {
    public var rect: RFBRect
    public var encoding: Int32
    /// Payload bytes after the 12-byte rectangle header.
    public var payloadBytes: Int
}

/// One FramebufferUpdate message the server sent.
public struct MockSentUpdate: Sendable, Equatable {
    public var rects: [MockSentRect]
}

/// One encoded rectangle: header fields plus payload (everything after the 12-byte header).
public struct MockEncodedRect: Sendable, Equatable {
    public var rect: RFBRect
    public var encoding: Int32
    public var payload: Data

    public init(rect: RFBRect, encoding: Int32, payload: Data) {
        self.rect = rect
        self.encoding = encoding
        self.payload = payload
    }

    /// The 12-byte rectangle header followed by the payload, as on the wire.
    public var wireBytes: Data {
        var b = ByteBuilder(capacity: 12 + payload.count)
        b.u16(UInt16(clamping: rect.x)); b.u16(UInt16(clamping: rect.y))
        b.u16(UInt16(clamping: rect.width)); b.u16(UInt16(clamping: rect.height))
        b.i32(encoding)
        b.bytes(payload)
        return b.data
    }
}
