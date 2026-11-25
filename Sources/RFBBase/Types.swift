import Foundation

/// A rectangle in remote framebuffer coordinates (origin top-left, units = remote pixels).
public struct RFBRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func union(_ other: RFBRect) -> RFBRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let nx = min(x, other.x), ny = min(y, other.y)
        return RFBRect(x: nx, y: ny, width: max(maxX, other.maxX) - nx, height: max(maxY, other.maxY) - ny)
    }
}

/// RFB PIXEL_FORMAT (RFC 6143 §7.4), 16 bytes on the wire.
public struct PixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColor: Bool,
                redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
                redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// The ONLY pixel format this client ever negotiates (via SetPixelFormat right after ServerInit).
    /// 32 bpp, depth 24, little-endian, R<<16 G<<8 B<<0. On the wire a pixel is the 4 bytes B, G, R, X.
    /// With this format: Tight TPIXEL and ZRLE CPIXEL are 3 bytes — Tight sends R,G,B; ZRLE sends the
    /// low 3 bytes of the little-endian pixel, i.e. B,G,R.
    public static let bgrx8888 = PixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
                                             redMax: 255, greenMax: 255, blueMax: 255,
                                             redShift: 16, greenShift: 8, blueShift: 0)

    public func encoded() -> Data {
        var b = ByteBuilder()
        b.u8(bitsPerPixel); b.u8(depth); b.u8(bigEndian ? 1 : 0); b.u8(trueColor ? 1 : 0)
        b.u16(redMax); b.u16(greenMax); b.u16(blueMax)
        b.u8(redShift); b.u8(greenShift); b.u8(blueShift)
        b.zeros(3)
        return b.data
    }

    /// Decodes the 16-byte wire form.
    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= 16 else { throw RFBError.protocolViolation("PIXEL_FORMAT needs 16 bytes") }
        bitsPerPixel = bytes[0]
        depth = bytes[1]
        bigEndian = bytes[2] != 0
        trueColor = bytes[3] != 0
        redMax = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        greenMax = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        blueMax = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        redShift = bytes[10]
        greenShift = bytes[11]
        blueShift = bytes[12]
    }
}

/// Encoding numbers (RFC 6143 §7.7/§7.8 plus the rfbproto community registry).
public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let rre: Int32 = 2
    public static let hextile: Int32 = 5
    public static let zlib: Int32 = 6
    public static let tight: Int32 = 7
    public static let zrle: Int32 = 16
    // Pseudo-encodings
    public static let cursor: Int32 = -239
    public static let desktopSize: Int32 = -223
    public static let lastRect: Int32 = -224
    public static let extendedDesktopSize: Int32 = -308
    /// Tight JPEG quality 0...9 → -32 ... -23
    public static func jpegQuality(_ level: Int) -> Int32 { Int32(-32 + max(0, min(9, level))) }
    /// Compression level 0...9 → -256 ... -247
    public static func compressionLevel(_ level: Int) -> Int32 { Int32(-256 + max(0, min(9, level))) }
}

/// Pointer button mask (RFC 6143 §7.5.5). Scroll is sent as a press+release of the wheel bits.
public struct RFBButtonMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = RFBButtonMask(rawValue: 1 << 0)
    public static let middle = RFBButtonMask(rawValue: 1 << 1)
    public static let right = RFBButtonMask(rawValue: 1 << 2)
    public static let wheelUp = RFBButtonMask(rawValue: 1 << 3)
    public static let wheelDown = RFBButtonMask(rawValue: 1 << 4)
    public static let wheelLeft = RFBButtonMask(rawValue: 1 << 5)
    public static let wheelRight = RFBButtonMask(rawValue: 1 << 6)
}

/// What the server told us in ServerInit, plus what was negotiated.
public struct ServerInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// The server's native pixel format from ServerInit (we override it with `PixelFormat.bgrx8888`).
    public var nativePixelFormat: PixelFormat
    public var name: String
    /// e.g. "003.889" as sent by the server.
    public var serverVersion: String
    /// The security type that was used (1 none, 2 VNC, 30 ARD DH, 33 Apple RSA ...).
    public var securityType: UInt8
    /// All security types the server offered.
    public var offeredSecurityTypes: [UInt8]

    public init(width: Int, height: Int, nativePixelFormat: PixelFormat, name: String,
                serverVersion: String, securityType: UInt8, offeredSecurityTypes: [UInt8]) {
        self.width = width
        self.height = height
        self.nativePixelFormat = nativePixelFormat
        self.name = name
        self.serverVersion = serverVersion
        self.securityType = securityType
        self.offeredSecurityTypes = offeredSecurityTypes
    }
}

/// Credentials the user can supply.
public enum RFBCredential: Sendable, Equatable {
    case none
    /// Classic VNC password (security type 2). Only the first 8 bytes are significant.
    case vncPassword(String)
    /// macOS account login (Apple security types 33 / 30).
    case macAccount(username: String, password: String)
}

/// Remote cursor image from the Cursor pseudo-encoding (-239).
public struct RFBCursor: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    /// width*height*4 bytes, memory order B,G,R,A, straight (non-premultiplied) alpha; A is 0 or 255.
    public var bgra: Data

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, bgra: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.bgra = bgra
    }
}

public enum RFBError: Error, Equatable, Sendable {
    /// The peer closed the connection or the stream was closed locally.
    case connectionClosed
    case connectionFailed(String)
    case timeout
    case protocolViolation(String)
    case unsupportedProtocolVersion(String)
    /// None of the offered security types can be used with the supplied credential.
    case noUsableSecurityType(offered: [UInt8])
    /// The server rejected the credentials (reason string if the server sent one).
    case authenticationFailed(String?)
    /// The user (or policy) rejected the server's public key.
    case hostKeyRejected
    case unsupportedEncoding(Int32)
    case decodeFailed(String)
    case cryptoFailed(String)
}
