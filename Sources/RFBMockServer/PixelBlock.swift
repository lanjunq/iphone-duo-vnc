import Foundation
import RFBBase

/// A rectangle of pixels as 24-bit values `R<<16 | G<<8 | B` (= the little-endian `bgrx8888` pixel
/// value with the padding byte zeroed). Row-major, no padding.
struct PixelBlock {
    let width: Int
    let height: Int
    var px: [UInt32]

    init(width: Int, height: Int, px: [UInt32]) {
        self.width = width
        self.height = height
        self.px = px
    }

    /// Copies `rect` out of the framebuffer (throws if out of bounds).
    init(framebuffer: Framebuffer, rect: RFBRect) throws {
        let bgra = try framebuffer.copyPixels(rect)
        width = rect.width
        height = rect.height
        var out = [UInt32](repeating: 0, count: rect.width * rect.height)
        bgra.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = 0
                for i in 0..<dst.count {
                    dst[i] = UInt32(src[s]) | UInt32(src[s + 1]) << 8 | UInt32(src[s + 2]) << 16
                    s += 4
                }
            }
        }
        px = out
    }

    func sub(x: Int, y: Int, width w: Int, height h: Int) -> PixelBlock {
        var out = [UInt32](repeating: 0, count: w * h)
        px.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    let s = (y + row) * width + x
                    for col in 0..<w { dst[row * w + col] = src[s + col] }
                }
            }
        }
        return PixelBlock(width: w, height: h, px: out)
    }

    /// Wire bytes in `bgrx8888`: B, G, R, 0 per pixel.
    func bgrxBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: px.count * 4)
        out.withUnsafeMutableBufferPointer { d in
            var o = 0
            for v in px {
                d[o] = UInt8(v & 0xff); d[o + 1] = UInt8((v >> 8) & 0xff); d[o + 2] = UInt8((v >> 16) & 0xff)
                o += 4
            }
        }
        return out
    }

    /// Distinct colours in first-appearance order, or nil if there are more than `limit`.
    func palette(limit: Int) -> [UInt32]? {
        var seen = [UInt32: Int]()
        var order = [UInt32]()
        var last: UInt32? = nil
        for v in px {
            if v == last { continue }
            last = v
            if seen[v] == nil {
                if order.count == limit { return nil }
                seen[v] = order.count
                order.append(v)
            }
        }
        return order
    }
}

@inline(__always) func appendBGRX(_ v: UInt32, to out: inout [UInt8]) {
    out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8((v >> 16) & 0xff)); out.append(0)
}

/// ZRLE CPIXEL for bgrx8888: the low three bytes of the little-endian pixel = B, G, R.
@inline(__always) func appendCPIXEL(_ v: UInt32, to out: inout [UInt8]) {
    out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8((v >> 16) & 0xff))
}

/// Tight TPIXEL for a 32bpp/depth-24/max-255 format: R, G, B.
@inline(__always) func appendTPIXEL(_ v: UInt32, to out: inout [UInt8]) {
    out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff))
}

extension RFBRect {
    func intersection(_ o: RFBRect) -> RFBRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        if x1 <= x0 || y1 <= y0 { return RFBRect(x: x0, y: y0, width: 0, height: 0) }
        return RFBRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func contains(_ o: RFBRect) -> Bool {
        o.x >= x && o.y >= y && o.maxX <= maxX && o.maxY <= maxY
    }

    func intersects(_ o: RFBRect) -> Bool { !intersection(o).isEmpty }

    /// Splits into tiles of at most `tw` x `th`, left-to-right, top-to-bottom.
    func tiles(width tw: Int, height th: Int) -> [RFBRect] {
        var out = [RFBRect]()
        var ty = y
        while ty < maxY {
            let h = min(th, maxY - ty)
            var tx = x
            while tx < maxX {
                let w = min(tw, maxX - tx)
                out.append(RFBRect(x: tx, y: ty, width: w, height: h))
                tx += w
            }
            ty += h
        }
        return out
    }
}
