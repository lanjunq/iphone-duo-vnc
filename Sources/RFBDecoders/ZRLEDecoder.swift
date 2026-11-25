import Foundation
import RFBBase

/// ZRLE (16): U32 length + zlib data (one stream per connection) that inflates to 64x64 tiles.
/// CPIXEL is 3 bytes B,G,R for `PixelFormat.bgrx8888`.
/// Tile subencodings: 0 raw, 1 solid, 2...16 packed palette, 128 plain RLE, 130...255 palette RLE.
public final class ZRLEDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.zrle
    let stream = InflateStream()

    public init() {}

    /// Worst-case inflated size of a w x h rectangle (plain RLE with one-pixel runs costs 4 bytes per
    /// pixel; a palette RLE tile adds up to 127 palette entries).
    static func maxUncompressedSize(width: Int, height: Int) -> Int {
        let tiles = ((width + 63) / 64) * ((height + 63) / 64)
        return width * height * 4 + tiles * 400 + 64
    }

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        let length = Int(try await reader.u32())
        let maxOut = Self.maxUncompressedSize(width: rect.width, height: rect.height)
        guard length <= compressedLengthLimit(forUncompressed: maxOut) else {
            throw RFBError.decodeFailed("ZRLE length \(length) too large for \(rect.width)x\(rect.height)")
        }
        let compressed = try await reader.bytes(length)
        let data = try stream.inflate(compressed, maxOutputSize: maxOut)
        if rect.isEmpty { return }
        // Tiles are decoded into a private 64x64 scratch buffer and written one at a time, so the
        // framebuffer lock is held per tile (microseconds), not for a whole 4K frame: the renderer on
        // the main thread never waits for a full-screen decode.
        var scratch = [UInt8](repeating: 255, count: 64 * 64 * 4)
        try data.withUnsafeBufferPointer { src in
            try scratch.withUnsafeMutableBufferPointer { sb in
                let tile = sb.baseAddress!
                var cur = ByteCursor(src)
                try Self.decodeTiles(rect: rect, cursor: &cur, scratch: tile) { tileRect in
                    try framebuffer.writeBGRX(tileRect, UnsafeRawBufferPointer(start: tile,
                                                                               count: tileRect.width * tileRect.height * 4))
                }
            }
        }
    }

    /// Decodes the tiles of `rect` in wire order (left to right, top to bottom). Each tile is written
    /// tightly packed (stride = tile width) into `scratch` (at least 64*64*4 bytes), then `emit` is
    /// called with the tile's framebuffer rectangle.
    static func decodeTiles(rect: RFBRect, cursor cur: inout ByteCursor, scratch p: UnsafeMutablePointer<UInt8>,
                            emit: (RFBRect) throws -> Void) throws {
        // Palette scratch: up to 127 entries of B,G,R.
        var palette = [UInt8](repeating: 0, count: 128 * 3)
        try palette.withUnsafeMutableBufferPointer { palBuf in
            let pal = palBuf.baseAddress!
            var ty = 0
            while ty < rect.height {
                let th = min(64, rect.height - ty)
                var tx = 0
                while tx < rect.width {
                    let tw = min(64, rect.width - tx)
                    let fbw = tw, ox = 0, oy = 0   // tile-local addressing into the scratch buffer
                    let total = tw * th

                    /// Writes `len` pixels of colour `c` starting at raster index `start` within the tile.
                    @inline(__always) func run(_ start: Int, _ len: Int, _ c: UnsafePointer<UInt8>) {
                        var i = start
                        let end = start + len
                        let b = c[0], g = c[1], r = c[2]
                        while i < end {
                            let row = i / tw, col = i - row * tw
                            let n = min(tw - col, end - i)
                            var q = p + ((oy + row) * fbw + ox + col) * 4
                            for _ in 0..<n {
                                q[0] = b; q[1] = g; q[2] = r; q[3] = 255
                                q += 4
                            }
                            i += n
                        }
                    }

                    func runLength(_ cur: inout ByteCursor, _ remaining: Int) throws -> Int {
                        var len = 1
                        while true {
                            let b = try cur.u8()
                            len += Int(b)
                            if b != 255 { break }
                            if len > remaining { break }
                        }
                        guard len <= remaining else {
                            throw RFBError.decodeFailed("ZRLE run of \(len) overflows tile (\(remaining) left)")
                        }
                        return len
                    }

                    let sub = Int(try cur.u8())
                    switch sub {
                    case 0:
                        var s = try cur.take(total * 3)
                        for row in 0..<th {
                            var q = p + ((oy + row) * fbw + ox) * 4
                            for _ in 0..<tw {
                                q[0] = s[0]; q[1] = s[1]; q[2] = s[2]; q[3] = 255
                                q += 4
                                s += 3
                            }
                        }
                    case 1:
                        let c = try cur.take(3)
                        run(0, total, c)
                    case 2...16:
                        let n = sub
                        let entries = try cur.take(n * 3)
                        pal.update(from: entries, count: n * 3)
                        let bits = n == 2 ? 1 : (n <= 4 ? 2 : 4)
                        let mask = (1 << bits) - 1
                        let rowBytes = (tw * bits + 7) / 8
                        let packed = try cur.take(rowBytes * th)
                        for row in 0..<th {
                            let line = packed + row * rowBytes
                            var q = p + ((oy + row) * fbw + ox) * 4
                            for col in 0..<tw {
                                let bit = col * bits
                                let idx = (Int(line[bit >> 3]) >> (8 - bits - (bit & 7))) & mask
                                guard idx < n else {
                                    throw RFBError.decodeFailed("ZRLE palette index \(idx) >= \(n)")
                                }
                                let c = pal + idx * 3
                                q[0] = c[0]; q[1] = c[1]; q[2] = c[2]; q[3] = 255
                                q += 4
                            }
                        }
                    case 128:
                        var i = 0
                        while i < total {
                            let c = try cur.take(3)
                            let len = try runLength(&cur, total - i)
                            run(i, len, c)
                            i += len
                        }
                    case 130...255:
                        let n = sub - 128
                        let entries = try cur.take(n * 3)
                        pal.update(from: entries, count: n * 3)
                        var i = 0
                        while i < total {
                            let b = try cur.u8()
                            let idx = Int(b & 0x7f)
                            guard idx < n else {
                                throw RFBError.decodeFailed("ZRLE palette index \(idx) >= \(n)")
                            }
                            let len = b & 0x80 != 0 ? try runLength(&cur, total - i) : 1
                            run(i, len, pal + idx * 3)
                            i += len
                        }
                    default:
                        throw RFBError.decodeFailed("ZRLE unused tile subencoding \(sub)")
                    }
                    try emit(RFBRect(x: rect.x + tx, y: rect.y + ty, width: tw, height: th))
                    tx += 64
                }
                ty += 64
            }
        }
    }
}
