import Foundation
import Testing
import RFBBase
@testable import RFBDecoders

/// Builds Hextile wire data and the expected image together, tile by tile.
private struct HextileBuilder {
    var img: Image
    var wire = [UInt8]()
    var bg: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var fg: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var rng = LCG(42)

    init(width: Int, height: Int) { img = Image(width: width, height: height) }

    func px(_ c: (UInt8, UInt8, UInt8)) -> [UInt8] { [c.0, c.1, c.2, 0x33] }
    mutating func colour() -> (UInt8, UInt8, UInt8) { (rng.next(), rng.next(), rng.next()) }

    /// Subrects that fit a tw x th tile, including ones touching the tile's right/bottom edge.
    func subrects(_ tw: Int, _ th: Int) -> [(Int, Int, Int, Int)] {
        [(0, 0, 1, 1), (tw - 1, th - 1, 1, 1), (max(0, tw - 3), 0, min(3, tw), th), (0, th / 2, tw, 1)]
    }

    mutating func tile(_ tx: Int, _ ty: Int, _ tw: Int, _ th: Int, mode: Int) {
        func paint(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8)) {
            for yy in y..<(y + h) { for xx in x..<(x + w) { img[tx + xx, ty + yy] = c } }
        }
        func xy(_ s: (Int, Int, Int, Int)) -> [UInt8] {
            [UInt8(s.0 << 4 | s.1), UInt8((s.2 - 1) << 4 | (s.3 - 1))]
        }
        switch mode {
        case 0: // background only
            bg = colour(); wire += [2] + px(bg); paint(0, 0, tw, th, bg)
        case 1: // raw (junk in the other mask bits must be ignored)
            wire += [1 | 2 | 8 | 16]
            for y in 0..<th { for x in 0..<tw { let c = colour(); img[tx + x, ty + y] = c; wire += px(c) } }
        case 2: // bg + fg + mono subrects
            bg = colour(); fg = colour()
            let s = subrects(tw, th)
            wire += [2 | 4 | 8] + px(bg) + px(fg) + [UInt8(s.count)]
            paint(0, 0, tw, th, bg)
            for r in s { wire += xy(r); paint(r.0, r.1, r.2, r.3, fg) }
        case 3: // bg and fg both carried over, mono subrects
            let s = subrects(tw, th)
            wire += [8, UInt8(s.count)]
            paint(0, 0, tw, th, bg)
            for r in s { wire += xy(r); paint(r.0, r.1, r.2, r.3, fg) }
        case 4: // bg + coloured subrects
            bg = colour()
            let s = subrects(tw, th)
            wire += [2 | 8 | 16] + px(bg) + [UInt8(s.count)]
            paint(0, 0, tw, th, bg)
            for r in s { let c = colour(); wire += px(c) + xy(r); paint(r.0, r.1, r.2, r.3, c) }
        case 5: // everything carried, no subrects: solid previous background
            wire += [0]; paint(0, 0, tw, th, bg)
        case 6: // AnySubrects with a count of zero
            bg = colour(); fg = colour()
            wire += [2 | 4 | 8] + px(bg) + px(fg) + [0]; paint(0, 0, tw, th, bg)
        case 7: // new fg only, bg carried
            fg = colour()
            let s = [(0, 0, tw, th)]   // full-tile subrect
            wire += [4 | 8] + px(fg) + [1] + xy(s[0])
            paint(0, 0, tw, th, fg)
        default:
            fatalError()
        }
    }
}

@Suite struct HextileTests {
    @Test(arguments: [(53, 37), (16, 16), (1, 1), (17, 33), (64, 5)])
    func allSubencodings(size: (Int, Int)) async throws {
        let (w, h) = size
        var b = HextileBuilder(width: w, height: h)
        // Sequence chosen so carried-over modes (3, 5, 7) follow tiles that set bg/fg; mode 1 (raw)
        // is never directly followed by a carry-over.
        let modes = [0, 3, 2, 3, 1, 4, 5, 6, 7, 3, 1, 2, 5]
        var i = 0
        for ty in stride(from: 0, to: h, by: 16) {
            for tx in stride(from: 0, to: w, by: 16) {
                var m = modes[i % modes.count]
                if i == 0 { m = 0 }
                b.tile(tx, ty, min(16, w - tx), min(16, h - ty), mode: m)
                i += 1
            }
        }
        let fb = Framebuffer(width: w + 5, height: h + 3)
        try await runDecoder(HextileDecoder(), rects: [RFBRect(x: 5, y: 3, width: w, height: h)], wire: b.wire, framebuffer: fb)
        try expectMatches(fb, b.img, at: (5, 3))
    }

    @Test func malformed() async {
        let fb = Framebuffer(width: 40, height: 40)
        // Subrect extends past a 5-pixel-wide edge tile: x=3, w=3.
        let bad = [UInt8(2 | 4 | 8), 0, 0, 0, 0, 9, 9, 9, 0, 1, UInt8(3 << 4), UInt8(2 << 4)]
        await expectDecodeThrows(HextileDecoder(), rect: RFBRect(x: 0, y: 0, width: 5, height: 5), wire: bad, framebuffer: fb)
        // Truncated raw tile.
        await expectDecodeThrows(HextileDecoder(), rect: RFBRect(x: 0, y: 0, width: 16, height: 16), wire: [1] + [UInt8](repeating: 0, count: 100), framebuffer: fb)
        // Count says 3 subrects, only 1 present.
        await expectDecodeThrows(HextileDecoder(), rect: RFBRect(x: 0, y: 0, width: 16, height: 16), wire: [2 | 8, 0, 0, 0, 0, 3, 0, 0], framebuffer: fb)
        // Out-of-bounds rect.
        await expectDecodeThrows(HextileDecoder(), rect: RFBRect(x: 30, y: 30, width: 16, height: 16), wire: [0], framebuffer: fb)
    }
}
