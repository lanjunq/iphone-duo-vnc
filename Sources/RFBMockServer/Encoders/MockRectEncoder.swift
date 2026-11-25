import Foundation
import RFBBase

/// Encodes framebuffer areas for one connection. Instances keep per-connection state (zlib streams),
/// so create one per connection and feed it rectangles in the order they are sent.
/// Pixels are always produced in `PixelFormat.bgrx8888`.
public protocol MockRectEncoder: AnyObject {
    /// The RFB encoding number written in each rectangle header.
    var encoding: Int32 { get }
    /// Encodes `rect` (must lie inside `framebuffer`). May split it into several wire rectangles,
    /// which together cover `rect` exactly, in the order they must be sent.
    func encode(_ rect: RFBRect, from framebuffer: Framebuffer) throws -> [MockEncodedRect]
}

/// Raw (0): width*height pixels, B,G,R,0.
public final class MockRawEncoder: MockRectEncoder {
    public let encoding = RFBEncoding.raw
    public init() {}

    public func encode(_ rect: RFBRect, from framebuffer: Framebuffer) throws -> [MockEncodedRect] {
        let block = try PixelBlock(framebuffer: framebuffer, rect: rect)
        return [MockEncodedRect(rect: rect, encoding: encoding, payload: Data(block.bgrxBytes()))]
    }
}

/// Zlib (6): u32 length + zlib data (one persistent stream) of the Raw pixel bytes.
public final class MockZlibEncoder: MockRectEncoder {
    public let encoding = RFBEncoding.zlib
    private let stream: DeflateStream

    /// `level` is the zlib level 0...9, fixed for the life of the stream.
    public init(level: Int = 6) { stream = DeflateStream(level: level) }

    public func encode(_ rect: RFBRect, from framebuffer: Framebuffer) throws -> [MockEncodedRect] {
        let block = try PixelBlock(framebuffer: framebuffer, rect: rect)
        let z = try stream.compress(block.bgrxBytes())
        var b = ByteBuilder(capacity: z.count + 4)
        b.u32(UInt32(z.count))
        b.bytes(z)
        return [MockEncodedRect(rect: rect, encoding: encoding, payload: b.data)]
    }
}

/// CopyRect (1) payload: u16 src-x, u16 src-y.
public enum MockCopyRect {
    public static func encode(dest: RFBRect, srcX: Int, srcY: Int) -> MockEncodedRect {
        var b = ByteBuilder()
        b.u16(UInt16(clamping: srcX)); b.u16(UInt16(clamping: srcY))
        return MockEncodedRect(rect: dest, encoding: RFBEncoding.copyRect, payload: b.data)
    }
}
