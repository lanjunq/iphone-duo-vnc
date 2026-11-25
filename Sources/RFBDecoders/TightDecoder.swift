import Foundation
import CoreGraphics
import ImageIO
import RFBBase

/// Tight (7). TPIXEL is 3 bytes R,G,B for `PixelFormat.bgrx8888`.
///
/// Compression-control byte: bits 0-3 reset zlib streams 0-3 (applied before anything else, for every
/// compression type); upper nibble 0x0-0x7 = BasicCompression (bits 4-5 stream id, bit 6 filter id
/// follows), 0x8 = Fill, 0x9 = JPEG, 0xA / 0xE = BasicCompression without zlib (0xE: filter id follows).
/// Filters: 0 copy, 1 palette (1-bit rows padded to a byte when 2 colours, else 8-bit), 2 gradient.
/// Filtered data shorter than 12 bytes is sent uncompressed; otherwise it is a compact length plus
/// zlib data through the selected persistent stream.
public final class TightDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.tight
    let streams: [InflateStream] = (0..<4).map { _ in InflateStream() }

    public init() {}

    /// Reads the 1-3 byte compact length: 7 bits, 7 bits, then a full 8-bit third byte (max 4194303).
    static func readCompactLength(_ reader: RFBReader) async throws -> Int {
        let b0 = try await reader.u8()
        var len = Int(b0 & 0x7f)
        if b0 & 0x80 == 0 { return len }
        let b1 = try await reader.u8()
        len |= Int(b1 & 0x7f) << 7
        if b1 & 0x80 == 0 { return len }
        let b2 = try await reader.u8()
        len |= Int(b2) << 14
        return len
    }

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        let control = try await reader.u8()
        for i in 0..<4 where control & (1 << i) != 0 {
            try streams[i].reset()
        }
        let method = control >> 4
        switch method {
        case 0x8:
            let px = try await reader.bytes(3)
            try framebuffer.fill(rect, blue: px[2], green: px[1], red: px[0])
        case 0x9:
            let length = try await Self.readCompactLength(reader)
            let jpeg = try await reader.bytes(length)
            if rect.isEmpty { return }
            guard length > 0 else { throw RFBError.decodeFailed("Tight JPEG with zero length") }
            let bgrx = try Self.decodeJPEG(jpeg, width: rect.width, height: rect.height)
            try framebuffer.writeBGRX(rect, bgrx)
        case 0x0...0x7:
            try await decodeBasic(rect: rect, reader: reader, framebuffer: framebuffer,
                                  stream: Int(method & 0x3), readFilter: method & 0x4 != 0, zlib: true)
        case 0xA:
            try await decodeBasic(rect: rect, reader: reader, framebuffer: framebuffer,
                                  stream: 0, readFilter: false, zlib: false)
        case 0xE:
            try await decodeBasic(rect: rect, reader: reader, framebuffer: framebuffer,
                                  stream: 0, readFilter: true, zlib: false)
        default:
            throw RFBError.decodeFailed(String(format: "Tight: invalid compression-control 0x%02x", control))
        }
    }

    private func decodeBasic(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer,
                             stream: Int, readFilter: Bool, zlib: Bool) async throws {
        let w = rect.width, h = rect.height
        let filter = readFilter ? try await reader.u8() : 0
        switch filter {
        case 0:
            let data = try await readData(size: w * h * 3, stream: stream, zlib: zlib, reader: reader)
            try framebuffer.write24(rect, data, rgbOrder: true)
        case 1:
            let colours = Int(try await reader.u8()) + 1
            let palette = try await reader.bytes(colours * 3)
            let rowBytes = colours == 2 ? (w + 7) / 8 : w
            let data = try await readData(size: rowBytes * h, stream: stream, zlib: zlib, reader: reader)
            if rect.isEmpty { return }
            let bgrx = try Self.expandPalette(data, palette: palette, colours: colours, width: w, height: h)
            try framebuffer.writeBGRX(rect, bgrx)
        case 2:
            let data = try await readData(size: w * h * 3, stream: stream, zlib: zlib, reader: reader)
            if rect.isEmpty { return }
            try framebuffer.writeBGRX(rect, Self.undoGradient(data, width: w, height: h))
        default:
            throw RFBError.decodeFailed("Tight: invalid filter id \(filter)")
        }
    }

    /// Reads `size` bytes of filtered data: raw when < 12 bytes (or without zlib), else compact length + zlib.
    private func readData(size: Int, stream: Int, zlib: Bool, reader: RFBReader) async throws -> [UInt8] {
        if !zlib || size < 12 { return try await reader.bytes(size) }
        let length = try await Self.readCompactLength(reader)
        guard length <= compressedLengthLimit(forUncompressed: size) else {
            throw RFBError.decodeFailed("Tight zlib length \(length) too large for \(size) bytes")
        }
        let compressed = try await reader.bytes(length)
        return try streams[stream].inflate(compressed, exactOutputSize: size)
    }

    static func expandPalette(_ data: [UInt8], palette: [UInt8], colours: Int, width w: Int, height h: Int) throws -> [UInt8] {
        // Palette as BGRX.
        var pal = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<colours {
            pal[i * 4] = palette[i * 3 + 2]; pal[i * 4 + 1] = palette[i * 3 + 1]; pal[i * 4 + 2] = palette[i * 3]
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        try out.withUnsafeMutableBufferPointer { ob in
            try data.withUnsafeBufferPointer { db in
                try pal.withUnsafeBufferPointer { pb in
                    let o = ob.baseAddress!, d = db.baseAddress!, pp = pb.baseAddress!
                    if colours == 2 {
                        let rowBytes = (w + 7) / 8
                        for y in 0..<h {
                            let line = d + y * rowBytes
                            var q = o + y * w * 4
                            for x in 0..<w {
                                let idx = Int(line[x >> 3] >> (7 - (x & 7))) & 1
                                let c = pp + idx * 4
                                q[0] = c[0]; q[1] = c[1]; q[2] = c[2]
                                q += 4
                            }
                        }
                    } else {
                        var q = o
                        for i in 0..<(w * h) {
                            let idx = Int(d[i])
                            guard idx < colours else {
                                throw RFBError.decodeFailed("Tight palette index \(idx) >= \(colours)")
                            }
                            let c = pp + idx * 4
                            q[0] = c[0]; q[1] = c[1]; q[2] = c[2]
                            q += 4
                        }
                    }
                }
            }
        }
        return out
    }

    /// Gradient filter inverse: V = D + clamp(left + up - upleft, 0, 255), per R,G,B component, with
    /// pixels outside the rectangle taken as 0. Input is R,G,B triples; output is B,G,R,X.
    static func undoGradient(_ data: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var prev = [Int](repeating: 0, count: w * 3)
        var cur = [Int](repeating: 0, count: w * 3)
        data.withUnsafeBufferPointer { db in
            out.withUnsafeMutableBufferPointer { ob in
                let d = db.baseAddress!, o = ob.baseAddress!
                var si = 0
                for y in 0..<h {
                    prev.withUnsafeMutableBufferPointer { pv in
                        cur.withUnsafeMutableBufferPointer { cv in
                            let up = pv.baseAddress!, c = cv.baseAddress!
                            var q = o + y * w * 4
                            for x in 0..<w {
                                for k in 0..<3 {
                                    let left = x > 0 ? c[(x - 1) * 3 + k] : 0
                                    let upLeft = x > 0 ? up[(x - 1) * 3 + k] : 0
                                    var pred = left + up[x * 3 + k] - upLeft
                                    if pred < 0 { pred = 0 } else if pred > 255 { pred = 255 }
                                    let v = (Int(d[si]) + pred) & 0xff
                                    si += 1
                                    c[x * 3 + k] = v
                                    q[2 - k] = UInt8(v)
                                }
                                q += 4
                            }
                        }
                    }
                    swap(&prev, &cur)
                }
            }
        }
        return out
    }

    /// Decodes a JFIF stream with ImageIO into B,G,R,X. The image must match the rectangle size.
    static func decodeJPEG(_ jpeg: [UInt8], width w: Int, height h: Int) throws -> [UInt8] {
        let options = [kCGImageSourceTypeIdentifierHint: "public.jpeg" as CFString] as CFDictionary
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RFBError.decodeFailed("Tight JPEG could not be decoded")
        }
        guard image.width == w, image.height == h else {
            throw RFBError.decodeFailed("Tight JPEG is \(image.width)x\(image.height), rect is \(w)x\(h)")
        }
        // Draw in the image's own RGB colour space so no colour conversion shifts the pixels.
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb { space = cs } else { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw RFBError.decodeFailed("Tight JPEG: cannot create bitmap context") }
        return out
    }
}
