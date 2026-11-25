import Foundation
import Testing
import RFBBase
@testable import RFBDecoders

private enum ZMode { case raw, solid, packed(Int), plainRLE, paletteRLE(Int) }

/// Builds the uncompressed ZRLE tile stream and the expected image together.
private struct ZRLEBuilder {
    var img: Image
    var data = [UInt8]()
    var rng: LCG

    init(width: Int, height: Int, seed: UInt64) { img = Image(width: width, height: height); rng = LCG(seed) }

    mutating func colour() -> (UInt8, UInt8, UInt8) { (rng.next(), rng.next(), rng.next()) }
    func cpixel(_ c: (UInt8, UInt8, UInt8)) -> [UInt8] { [c.0, c.1, c.2] }   // B,G,R

    static func runLengthBytes(_ len: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: (len - 1) / 255)
        out.append(UInt8((len - 1) % 255))
        return out
    }

    /// Run lengths that cross rows and exercise the 255-continuation boundary values.
    static func runs(total: Int) -> [Int] {
        let pattern = [1, 254, 255, 256, 2, 510, 511, 3, 64, 1, 1, 765, 766]
        var out = [Int](), left = total, i = 0
        while left > 0 { let n = min(left, pattern[i % pattern.count]); out.append(n); left -= n; i += 1 }
        return out
    }

    mutating func tile(_ tx: Int, _ ty: Int, _ tw: Int, _ th: Int, _ mode: ZMode) {
        let total = tw * th
        func set(_ i: Int, _ c: (UInt8, UInt8, UInt8)) { img[tx + i % tw, ty + i / tw] = c }
        switch mode {
        case .raw:
            data.append(0)
            for i in 0..<total { let c = colour(); set(i, c); data += cpixel(c) }
        case .solid:
            let c = colour(); data.append(1); data += cpixel(c)
            for i in 0..<total { set(i, c) }
        case .packed(let n):
            let pal = (0..<n).map { _ in colour() }
            data.append(UInt8(n)); for c in pal { data += cpixel(c) }
            let bits = n == 2 ? 1 : (n <= 4 ? 2 : 4)
            for y in 0..<th {
                var byte = 0, used = 0
                for x in 0..<tw {
                    let idx = (x * 3 + y * 5 + x * y) % n
                    img[tx + x, ty + y] = pal[idx]
                    byte = byte << bits | idx; used += bits
                    if used == 8 { data.append(UInt8(byte)); byte = 0; used = 0 }
                }
                if used > 0 { data.append(UInt8(byte << (8 - used))) }   // pad row to a byte boundary
            }
        case .plainRLE:
            data.append(128)
            var i = 0
            for len in Self.runs(total: total) {
                let c = colour(); data += cpixel(c) + Self.runLengthBytes(len)
                for k in i..<(i + len) { set(k, c) }
                i += len
            }
        case .paletteRLE(let want):
            let n = max(2, min(want, 127))
            let pal = (0..<n).map { _ in colour() }
            data.append(UInt8(128 + n)); for c in pal { data += cpixel(c) }
            var i = 0, r = 0
            for len in Self.runs(total: total) {
                let idx = (r * 7) % n; r += 1
                if len == 1 { data.append(UInt8(idx)) } else { data += [UInt8(idx | 0x80)] + Self.runLengthBytes(len) }
                for k in i..<(i + len) { set(k, pal[idx]) }
                i += len
            }
        }
    }

    mutating func build(modes: [ZMode]) {
        var i = 0
        for ty in stride(from: 0, to: img.height, by: 64) {
            for tx in stride(from: 0, to: img.width, by: 64) {
                tile(tx, ty, min(64, img.width - tx), min(64, img.height - ty), modes[i % modes.count])
                i += 1
            }
        }
    }
}

private let allModes: [ZMode] = [.raw, .solid, .packed(2), .packed(3), .packed(4), .packed(5), .packed(16),
                                  .plainRLE, .paletteRLE(2), .paletteRLE(3), .paletteRLE(127), .packed(7)]

@Suite struct ZRLETests {
    @Test func allSubencodingsTwoRectsOneStream() async throws {
        let fb = Framebuffer(width: 400, height: 300)
        var a = ZRLEBuilder(width: 130, height: 70, seed: 1)    // tiles 64,64,2 x 64,6
        a.build(modes: allModes)
        var b = ZRLEBuilder(width: 200, height: 100, seed: 2)   // tiles 64,64,64,8 x 64,36
        b.build(modes: Array(allModes.reversed()))
        let deflater = Deflater()
        let ca = deflater.compress(a.data), cb = deflater.compress(b.data)
        let wire = be32(ca.count) + ca + be32(cb.count) + cb
        try await runDecoder(ZRLEDecoder(), rects: [RFBRect(x: 3, y: 5, width: 130, height: 70),
                                                     RFBRect(x: 199, y: 200, width: 200, height: 100)],
                             wire: wire, framebuffer: fb)
        try expectMatches(fb, a.img, at: (3, 5))
        try expectMatches(fb, b.img, at: (199, 200))
    }

    @Test(arguments: [(1, 1), (63, 65), (64, 64), (65, 1), (7, 129)])
    func oddSizes(size: (Int, Int)) async throws {
        for (k, mode) in allModes.enumerated() {
            var b = ZRLEBuilder(width: size.0, height: size.1, seed: UInt64(k + 10))
            if case .packed(let n) = mode, n > size.0 * size.1 { continue }
            b.build(modes: [mode])
            let fb = Framebuffer(width: size.0, height: size.1)
            let c = Deflater().compress(b.data)
            try await runDecoder(ZRLEDecoder(), rects: [RFBRect(x: 0, y: 0, width: size.0, height: size.1)],
                                 wire: be32(c.count) + c, framebuffer: fb)
            try expectMatches(fb, b.img, at: (0, 0))
        }
    }

    @Test func secondRectNeedsTheSharedStream() async throws {
        var a = ZRLEBuilder(width: 64, height: 64, seed: 5)
        a.build(modes: [.raw])
        let d = Deflater()
        _ = d.compress(a.data)
        let c2 = d.compress(a.data)
        let fb = Framebuffer(width: 64, height: 64)
        await expectDecodeThrows(ZRLEDecoder(), rect: RFBRect(x: 0, y: 0, width: 64, height: 64), wire: be32(c2.count) + c2, framebuffer: fb)
    }

    @Test func largeFrame() async throws {
        // Full HiDPI-half frame, mostly raw tiles: must decode in reasonable time even in debug builds.
        var b = ZRLEBuilder(width: 1920, height: 1080, seed: 3)
        b.build(modes: [.raw, .solid, .paletteRLE(5), .packed(4), .plainRLE])
        let c = Deflater(level: 1).compress(b.data)
        let fb = Framebuffer(width: 1920, height: 1080)
        let start = Date()
        try await runDecoder(ZRLEDecoder(), rects: [RFBRect(x: 0, y: 0, width: 1920, height: 1080)], wire: be32(c.count) + c, framebuffer: fb)
        let elapsed = Date().timeIntervalSince(start)
        try expectMatches(fb, b.img, at: (0, 0))
        #expect(elapsed < 20, "ZRLE 1920x1080 took \(elapsed) s")
    }

    private func expectBadTileStream(_ tiles: [UInt8], w: Int = 4, h: Int = 2, sourceLocation: SourceLocation = #_sourceLocation) async {
        let c = Deflater().compress(tiles)
        let fb = Framebuffer(width: 16, height: 16)
        await expectDecodeThrows(ZRLEDecoder(), rect: RFBRect(x: 0, y: 0, width: w, height: h), wire: be32(c.count) + c,
                                 framebuffer: fb, sourceLocation: sourceLocation)
    }

    @Test func malformed() async {
        await expectBadTileStream([17])                                        // unused subencoding
        await expectBadTileStream([129])                                       // unused subencoding
        await expectBadTileStream([3, 0,0,0, 1,1,1, 2,2,2, 0xff, 0x00])        // packed index 3 >= 3
        await expectBadTileStream([131, 0,0,0, 1,1,1, 2,2,2, 5])               // palette RLE index 5 >= 3
        await expectBadTileStream([128, 1, 2, 3, 8])                           // run of 9 > 8 pixels
        await expectBadTileStream([128, 1, 2, 3, 255, 255, 255, 255])          // run continues past the data
        await expectBadTileStream([0] + [UInt8](repeating: 9, count: 20))      // raw tile 4 bytes short
        await expectBadTileStream([1, 1, 2])                                   // solid tile pixel short
        await expectBadTileStream([])                                          // no tile at all
        // Truncated compressed payload and garbage.
        let fb = Framebuffer(width: 16, height: 16)
        let c = Deflater().compress([1, 1, 2, 3])
        await expectDecodeThrows(ZRLEDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 2), wire: be32(c.count + 10) + c, framebuffer: fb)
        await expectDecodeThrows(ZRLEDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 2), wire: be32(8) + [1, 2, 3, 4, 5, 6, 7, 8], framebuffer: fb)
        await expectDecodeThrows(ZRLEDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 2), wire: be32(0x7fff_ffff), framebuffer: fb)
        await expectDecodeThrows(ZRLEDecoder(), rect: RFBRect(x: 14, y: 0, width: 4, height: 2), wire: be32(c.count) + c, framebuffer: fb)
    }
}
