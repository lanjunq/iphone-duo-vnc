import Foundation
import CoreGraphics
import ImageIO
import RFBBase

/// Tight (7), rfbproto "Tight Encoding", for a 32bpp / depth 24 / max 255 pixel format (TPIXEL = R,G,B).
///
/// Rectangles are split into tiles of at most 256x256 (well under the 2048-pixel width limit). Per tile:
/// - 1 colour → Fill (0x80 + TPIXEL)
/// - 2...256 colours → basic compression with the palette filter (2 colours: 1 bit per pixel, rows padded)
/// - more colours → JPEG (0x90) when `jpegQuality` is set (the client sent a JPEG quality pseudo-encoding),
///   else the gradient filter for smooth content, else the copy filter.
/// Basic data shorter than 12 bytes is sent uncompressed without a length; otherwise compact length +
/// zlib data. Streams: 0 = copy, 1 = 2-colour palette, 2 = palette, 3 = gradient; all persistent, never reset.
public final class MockTightEncoder: MockRectEncoder {
    public let encoding = RFBEncoding.tight

    public enum Mode: Sendable, Equatable { case fill, copy, palette, gradient, jpeg }

    /// JPEG quality level 0...9 from the client's pseudo-encoding, or nil to never use JPEG.
    public var jpegQuality: Int?
    /// Forces a mode where valid (fill needs one colour, palette 2...256 colours); else automatic.
    /// Forcing `.jpeg` works even when `jpegQuality` is nil (quality 6 is used).
    public var forcedMode: Mode?
    /// Maximum tile edge (1...2048).
    public var maxTileSize: Int = 256

    private let streams: [DeflateStream]
    /// Mode chosen for each tile of the last `encode` call (for tests).
    public private(set) var lastModes: [Mode] = []

    /// `compressionLevel` is the zlib level 0...9, fixed for the life of the streams.
    public init(compressionLevel: Int = 6, jpegQuality: Int? = nil, forcedMode: Mode? = nil) {
        streams = (0..<4).map { _ in DeflateStream(level: compressionLevel) }
        self.jpegQuality = jpegQuality
        self.forcedMode = forcedMode
    }

    public func encode(_ rect: RFBRect, from framebuffer: Framebuffer) throws -> [MockEncodedRect] {
        lastModes = []
        let edge = max(1, min(2048, maxTileSize))
        var out = [MockEncodedRect]()
        for tile in rect.tiles(width: edge, height: edge) {
            let block = try PixelBlock(framebuffer: framebuffer, rect: tile)
            out.append(MockEncodedRect(rect: tile, encoding: encoding, payload: Data(try encodeTile(block))))
        }
        return out
    }

    static func compactLength(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= 0x3FFFFF else { throw RFBError.protocolViolation("Tight length \(n) too large") }
        if n < 0x80 { return [UInt8(n)] }
        if n < 0x4000 { return [UInt8(n & 0x7F) | 0x80, UInt8(n >> 7)] }
        return [UInt8(n & 0x7F) | 0x80, UInt8((n >> 7) & 0x7F) | 0x80, UInt8(n >> 14)]
    }

    private func basicData(_ data: [UInt8], stream: Int, into out: inout [UInt8]) throws {
        if data.count < 12 {
            out.append(contentsOf: data)
            return
        }
        let z = try streams[stream].compress(data)
        out.append(contentsOf: try Self.compactLength(z.count))
        out.append(contentsOf: z)
    }

    func encodeTile(_ t: PixelBlock) throws -> [UInt8] {
        let palette = t.palette(limit: 256)
        var mode: Mode
        if let p = palette, p.count == 1 {
            mode = .fill
        } else if palette != nil {
            mode = .palette
        } else if jpegQuality != nil {
            mode = .jpeg
        } else {
            mode = Self.looksSmooth(t) ? .gradient : .copy
        }
        if let f = forcedMode {
            switch f {
            case .fill: if palette?.count == 1 { mode = .fill }
            case .palette: if let p = palette, p.count >= 2 { mode = .palette }
            case .copy, .gradient, .jpeg: mode = f
            }
        }
        lastModes.append(mode)

        var out = [UInt8]()
        switch mode {
        case .fill:
            out.append(0x80)
            appendTPIXEL(t.px[0], to: &out)
        case .jpeg:
            let jpeg = try Self.jpegData(t, quality: jpegQuality ?? 6)
            out.append(0x90)
            out.append(contentsOf: try Self.compactLength(jpeg.count))
            out.append(contentsOf: jpeg)
        case .copy:
            out.append(0x00)   // stream 0, no explicit filter = copy
            var data = [UInt8]()
            data.reserveCapacity(t.px.count * 3)
            for v in t.px { appendTPIXEL(v, to: &data) }
            try basicData(data, stream: 0, into: &out)
        case .palette:
            let p = palette!
            let stream = p.count == 2 ? 1 : 2
            out.append(0x40 | UInt8(stream << 4))
            out.append(1)                     // filter id: palette
            out.append(UInt8(p.count - 1))
            for v in p { appendTPIXEL(v, to: &out) }
            var index = [UInt32: UInt8]()
            for (k, v) in p.enumerated() { index[v] = UInt8(k) }
            var data = [UInt8]()
            if p.count == 2 {
                for y in 0..<t.height {
                    var byte: UInt8 = 0
                    var used = 0
                    for x in 0..<t.width {
                        if index[t.px[y * t.width + x]]! == 1 { byte |= 0x80 >> UInt8(used) }
                        used += 1
                        if used == 8 { data.append(byte); byte = 0; used = 0 }
                    }
                    if used > 0 { data.append(byte) }
                }
            } else {
                data.reserveCapacity(t.px.count)
                for v in t.px { data.append(index[v]!) }
            }
            try basicData(data, stream: stream, into: &out)
        case .gradient:
            out.append(0x40 | UInt8(3 << 4))
            out.append(2)                     // filter id: gradient
            try basicData(Self.gradientFilter(t), stream: 3, into: &out)
        }
        return out
    }

    /// Gradient filter (rfbproto): per component, value - clamp(left + up - upleft, 0, 255), mod 256,
    /// with pixels outside the rectangle taken as 0. Output order R, G, B.
    static func gradientFilter(_ t: PixelBlock) -> [UInt8] {
        let w = t.width, h = t.height
        var out = [UInt8](repeating: 0, count: w * h * 3)
        var o = 0
        for y in 0..<h {
            for x in 0..<w {
                let v = t.px[y * w + x]
                let left: UInt32 = x > 0 ? t.px[y * w + x - 1] : 0
                let up: UInt32 = y > 0 ? t.px[(y - 1) * w + x] : 0
                let upLeft: UInt32 = (x > 0 && y > 0) ? t.px[(y - 1) * w + x - 1] : 0
                for shift: UInt32 in [16, 8, 0] {
                    let c = Int((v >> shift) & 0xff)
                    let pred = max(0, min(255, Int((left >> shift) & 0xff) + Int((up >> shift) & 0xff) - Int((upLeft >> shift) & 0xff)))
                    out[o] = UInt8((c - pred) & 0xff)
                    o += 1
                }
            }
        }
        return out
    }

    /// Heuristic: use the gradient filter when most residual bytes are zero.
    static func looksSmooth(_ t: PixelBlock) -> Bool {
        let g = gradientFilter(t)
        var zeros = 0
        for b in g where b == 0 { zeros += 1 }
        return zeros * 2 > g.count
    }

    /// Baseline JPEG of the tile via ImageIO. `quality` 0...9.
    static func jpegData(_ t: PixelBlock, quality: Int) throws -> [UInt8] {
        let bgrx = t.bgrxBytes()
        guard let provider = CGDataProvider(data: Data(bgrx) as CFData) else {
            throw RFBError.protocolViolation("JPEG: no data provider")
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: t.width, height: t.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: t.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RFBError.protocolViolation("JPEG: CGImage creation failed")
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw RFBError.protocolViolation("JPEG: no ImageIO destination")
        }
        let q = Double(max(0, min(9, quality)) + 1) / 10.0
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RFBError.protocolViolation("JPEG: encode failed") }
        return [UInt8](data as Data)
    }
}
