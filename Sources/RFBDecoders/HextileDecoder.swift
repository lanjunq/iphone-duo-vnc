import Foundation
import RFBBase

/// Hextile (5): 16x16 tiles, each with a subencoding mask
/// (1 Raw, 2 BackgroundSpecified, 4 ForegroundSpecified, 8 AnySubrects, 16 SubrectsColoured).
/// Background and foreground carry over from tile to tile within a rectangle. When a server violates
/// the spec by relying on a value that is formally undefined (after a raw tile, or the foreground
/// after a SubrectsColoured tile), the last value seen is used, like libvncclient.
public final class HextileDecoder: RectDecoder {
    public let encoding: Int32 = RFBEncoding.hextile

    public init() {}

    public func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        try validate(rect, in: framebuffer)
        if rect.isEmpty { return }
        var bg: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var fg: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var tile = [UInt8](repeating: 255, count: 16 * 16 * 4)

        var ty = 0
        while ty < rect.height {
            let th = min(16, rect.height - ty)
            var tx = 0
            while tx < rect.width {
                let tw = min(16, rect.width - tx)
                let tileRect = RFBRect(x: rect.x + tx, y: rect.y + ty, width: tw, height: th)
                let mask = try await reader.u8()
                if mask & 1 != 0 {
                    let px = try await reader.bytes(tw * th * 4)
                    try framebuffer.writeBGRX(tileRect, px)
                    tx += 16
                    continue
                }
                if mask & 2 != 0 {
                    let p = try await reader.bytes(4)
                    bg = (p[0], p[1], p[2])
                }
                if mask & 4 != 0 {
                    let p = try await reader.bytes(4)
                    fg = (p[0], p[1], p[2])
                }
                var count = 0
                if mask & 8 != 0 { count = Int(try await reader.u8()) }
                let coloured = mask & 16 != 0
                let sub = try await reader.bytes(count * (coloured ? 6 : 2))

                // Paint the tile locally (tightly packed tw x th), then write it once.
                var lastColour = fg
                try tile.withUnsafeMutableBufferPointer { tb in
                    let t = tb.baseAddress!
                    var i = 0
                    while i < tw * th * 4 {
                        t[i] = bg.0; t[i + 1] = bg.1; t[i + 2] = bg.2; t[i + 3] = 255
                        i += 4
                    }
                    var o = 0
                    for _ in 0..<count {
                        var c = fg
                        if coloured {
                            c = (sub[o], sub[o + 1], sub[o + 2])
                            o += 4
                            lastColour = c
                        }
                        let xy = Int(sub[o]), wh = Int(sub[o + 1])
                        o += 2
                        let sx = xy >> 4, sy = xy & 15
                        let sw = (wh >> 4) + 1, sh = (wh & 15) + 1
                        guard sx + sw <= tw, sy + sh <= th else {
                            throw RFBError.decodeFailed("Hextile subrect (\(sx),\(sy) \(sw)x\(sh)) outside tile \(tw)x\(th)")
                        }
                        for row in sy..<(sy + sh) {
                            var q = t + (row * tw + sx) * 4
                            for _ in 0..<sw {
                                q[0] = c.0; q[1] = c.1; q[2] = c.2
                                q += 4
                            }
                        }
                    }
                    try framebuffer.writeBGRX(tileRect, UnsafeRawBufferPointer(start: t, count: tw * th * 4))
                }
                if coloured { fg = lastColour }
                tx += 16
            }
            ty += 16
        }
    }
}
