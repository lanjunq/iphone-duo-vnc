import Foundation
import RFBBase

/// Hextile (5), RFC 6143 §7.7.4. 16x16 tiles; each tile is Raw, solid background, or background plus
/// subrectangles (single foreground colour or individually coloured), whichever is smaller.
///
/// Conservative about persistence (like libvncserver): background/foreground are re-sent after a Raw tile,
/// and the foreground is re-sent after a tile with coloured subrectangles.
public final class MockHextileEncoder: MockRectEncoder {
    public let encoding = RFBEncoding.hextile
    public init() {}

    static let rawFlag: UInt8 = 1, bgFlag: UInt8 = 2, fgFlag: UInt8 = 4, anySubrects: UInt8 = 8, coloured: UInt8 = 16

    struct Subrect { var color: UInt32; var x: Int; var y: Int; var w: Int; var h: Int }

    public func encode(_ rect: RFBRect, from framebuffer: Framebuffer) throws -> [MockEncodedRect] {
        let block = try PixelBlock(framebuffer: framebuffer, rect: rect)
        var out = [UInt8]()
        out.reserveCapacity(rect.width * rect.height)
        var bg: UInt32? = nil
        var fg: UInt32? = nil
        var ty = 0
        while ty < rect.height {
            let th = min(16, rect.height - ty)
            var tx = 0
            while tx < rect.width {
                let tw = min(16, rect.width - tx)
                let tile = block.sub(x: tx, y: ty, width: tw, height: th)
                Self.encodeTile(tile, bg: &bg, fg: &fg, into: &out)
                tx += tw
            }
            ty += th
        }
        return [MockEncodedRect(rect: rect, encoding: encoding, payload: Data(out))]
    }

    static func encodeTile(_ t: PixelBlock, bg: inout UInt32?, fg: inout UInt32?, into out: inout [UInt8]) {
        let n = t.width * t.height
        // Most frequent colour becomes the background.
        var counts = [UInt32: Int]()
        for v in t.px { counts[v, default: 0] += 1 }
        let background = counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!.key
        let rawSize = 1 + n * 4

        if counts.count == 1 {
            if bg == background {
                out.append(0)
            } else {
                out.append(bgFlag); appendBGRX(background, to: &out)
                bg = background
            }
            return
        }

        let subrects = findSubrects(t, background: background)
        let twoColours = counts.count == 2
        let bgCost = bg == background ? 0 : 4
        var size: Int
        if twoColours {
            let foreground = subrects[0].color
            size = 1 + bgCost + (fg == foreground ? 0 : 4) + 1 + 2 * subrects.count
        } else {
            size = 1 + bgCost + 1 + 6 * subrects.count
        }
        if subrects.count > 255 || size >= rawSize {
            out.append(rawFlag)
            out.append(contentsOf: t.bgrxBytes())
            bg = nil
            fg = nil
            return
        }
        var mask = anySubrects
        if bg != background { mask |= bgFlag }
        if twoColours {
            let foreground = subrects[0].color
            if fg != foreground { mask |= fgFlag }
            out.append(mask)
            if mask & bgFlag != 0 { appendBGRX(background, to: &out) }
            if mask & fgFlag != 0 { appendBGRX(foreground, to: &out) }
            out.append(UInt8(subrects.count))
            for s in subrects {
                out.append(UInt8(s.x << 4 | s.y)); out.append(UInt8((s.w - 1) << 4 | (s.h - 1)))
            }
            fg = foreground
        } else {
            mask |= coloured
            out.append(mask)
            if mask & bgFlag != 0 { appendBGRX(background, to: &out) }
            out.append(UInt8(subrects.count))
            for s in subrects {
                appendBGRX(s.color, to: &out)
                out.append(UInt8(s.x << 4 | s.y)); out.append(UInt8((s.w - 1) << 4 | (s.h - 1)))
            }
            fg = nil
        }
        bg = background
    }

    /// Greedy cover of all non-background pixels with single-colour rectangles.
    static func findSubrects(_ t: PixelBlock, background: UInt32) -> [Subrect] {
        let w = t.width, h = t.height
        var covered = [Bool](repeating: false, count: w * h)
        var out = [Subrect]()
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let c = t.px[i]
                if c == background || covered[i] { continue }
                var rw = 1
                while x + rw < w && t.px[i + rw] == c && !covered[i + rw] { rw += 1 }
                var rh = 1
                grow: while y + rh < h {
                    let row = (y + rh) * w + x
                    for k in 0..<rw where t.px[row + k] != c || covered[row + k] { break grow }
                    rh += 1
                }
                for yy in y..<(y + rh) { for xx in x..<(x + rw) { covered[yy * w + xx] = true } }
                out.append(Subrect(color: c, x: x, y: y, w: rw, h: rh))
                if out.count > 256 { return out }   // caller falls back to Raw
            }
        }
        return out
    }
}
