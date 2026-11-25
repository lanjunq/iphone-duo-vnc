import Foundation
import RFBBase

/// Raw (0): width*height wire pixels (B,G,R,X). Read in bands of rows to bound memory.
public final class RawDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.raw
    /// Target bytes per bulk read.
    static let bandBytes = 1 << 20

    public init() {}

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        if rect.isEmpty { return }
        let rowBytes = rect.width * 4
        let bandRows = max(1, Self.bandBytes / rowBytes)
        var y = 0
        while y < rect.height {
            let rows = min(bandRows, rect.height - y)
            let pixels = try await reader.bytes(rows * rowBytes)
            try framebuffer.writeBGRX(RFBRect(x: rect.x, y: rect.y + y, width: rect.width, height: rows), pixels)
            y += rows
        }
    }
}

/// CopyRect (1): src-x, src-y (U16 each); copies an area already in the framebuffer.
public final class CopyRectDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.copyRect

    public init() {}

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        let sx = Int(try await reader.u16())
        let sy = Int(try await reader.u16())
        try validate(RFBRect(x: sx, y: sy, width: rect.width, height: rect.height), in: framebuffer)
        try framebuffer.copy(fromX: sx, y: sy, to: rect)
    }
}

/// RRE (2): U32 subrect count, background PIXEL, then count x (PIXEL, U16 x, y, w, h).
public final class RREDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.rre
    /// Subrectangles read per bulk read (12 bytes each).
    static let batch = 4096

    public init() {}

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        let count = Int(try await reader.u32())
        let bg = try await reader.bytes(4)
        try framebuffer.fill(rect, blue: bg[0], green: bg[1], red: bg[2])
        var left = count
        while left > 0 {
            let n = min(left, Self.batch)
            let d = try await reader.bytes(n * 12)
            for i in 0..<n {
                let o = i * 12
                let sx = Int(d[o + 4]) << 8 | Int(d[o + 5])
                let sy = Int(d[o + 6]) << 8 | Int(d[o + 7])
                let sw = Int(d[o + 8]) << 8 | Int(d[o + 9])
                let sh = Int(d[o + 10]) << 8 | Int(d[o + 11])
                guard sx + sw <= rect.width, sy + sh <= rect.height else {
                    throw RFBError.decodeFailed("RRE subrect (\(sx),\(sy) \(sw)x\(sh)) outside \(rect.width)x\(rect.height)")
                }
                try framebuffer.fill(RFBRect(x: rect.x + sx, y: rect.y + sy, width: sw, height: sh),
                                     blue: d[o], green: d[o + 1], red: d[o + 2])
            }
            left -= n
        }
    }
}

/// Zlib (6): U32 length + zlib data that inflates to a Raw rectangle. One stream per connection.
public final class ZlibDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.zlib
    let stream = InflateStream()

    public init() {}

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        let length = Int(try await reader.u32())
        let rawSize = rect.width * rect.height * 4
        guard length <= compressedLengthLimit(forUncompressed: rawSize) else {
            throw RFBError.decodeFailed("Zlib length \(length) too large for \(rect.width)x\(rect.height)")
        }
        let compressed = try await reader.bytes(length)
        let pixels = try stream.inflate(compressed, exactOutputSize: rawSize)
        try framebuffer.writeBGRX(rect, pixels)
    }
}
