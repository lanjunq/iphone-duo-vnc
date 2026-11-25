import Foundation
import Testing
import RFBBase
@testable import RFBDecoders

private func noiseImage(_ w: Int, _ h: Int, seed: UInt64) -> Image {
    var img = Image(width: w, height: h)
    var rng = LCG(seed)
    img.bgr = rng.bytes(w * h * 3)
    return img
}

private func rawWire(_ img: Image) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(img.width * img.height * 4)
    for y in 0..<img.height { for x in 0..<img.width { out += img.pixel(x, y) } }
    return out
}

@Suite struct RawTests {
    @Test func smallRectAtOffset() async throws {
        let fb = Framebuffer(width: 20, height: 10)
        let img = noiseImage(5, 3, seed: 1)
        try await runDecoder(RawDecoder(), rects: [RFBRect(x: 7, y: 4, width: 5, height: 3)], wire: rawWire(img), framebuffer: fb)
        try expectMatches(fb, img, at: (7, 4))
        #expect(fb.pixel(x: 6, y: 4) == (0, 0, 0))
    }

    @Test func multiBandRect() async throws {
        // 1000 x 300 x 4 = 1.2 MB > one 1 MB band.
        let fb = Framebuffer(width: 1000, height: 300)
        let img = noiseImage(1000, 300, seed: 2)
        try await runDecoder(RawDecoder(), rects: [RFBRect(x: 0, y: 0, width: 1000, height: 300)], wire: rawWire(img), framebuffer: fb)
        try expectMatches(fb, img, at: (0, 0))
    }

    @Test func emptyRectConsumesNothing() async throws {
        let fb = Framebuffer(width: 4, height: 4)
        try await runDecoder(RawDecoder(), rects: [RFBRect(x: 1, y: 1, width: 0, height: 3)], wire: [], framebuffer: fb)
    }

    @Test func outOfBoundsRectThrowsBeforeReading() async {
        let fb = Framebuffer(width: 10, height: 10)
        await expectDecodeThrows(RawDecoder(), rect: RFBRect(x: 8, y: 0, width: 3, height: 1), wire: [UInt8](repeating: 0, count: 12), framebuffer: fb)
        // A huge rect must be rejected without trying to read 17 GB.
        await expectDecodeThrows(RawDecoder(), rect: RFBRect(x: 0, y: 0, width: 65535, height: 65535), wire: [], framebuffer: fb)
    }

    @Test func truncatedThrows() async {
        let fb = Framebuffer(width: 10, height: 10)
        await expectDecodeThrows(RawDecoder(), rect: RFBRect(x: 0, y: 0, width: 2, height: 2), wire: [UInt8](repeating: 1, count: 15), framebuffer: fb)
    }
}

@Suite struct CopyRectTests {
    @Test func copiesOverlapping() async throws {
        let fb = Framebuffer(width: 10, height: 10)
        let img = noiseImage(10, 10, seed: 3)
        try await runDecoder(RawDecoder(), rects: [RFBRect(x: 0, y: 0, width: 10, height: 10)], wire: rawWire(img), framebuffer: fb)
        // Move the 6x6 block at (1,1) to (3,2): overlapping.
        try await runDecoder(CopyRectDecoder(), rects: [RFBRect(x: 3, y: 2, width: 6, height: 6)], wire: be16(1) + be16(1), framebuffer: fb)
        var expected = Image(width: 6, height: 6)
        for y in 0..<6 { for x in 0..<6 { expected[x, y] = img[x + 1, y + 1] } }
        try expectMatches(fb, expected, at: (3, 2))
        #expect(fb.pixel(x: 0, y: 0) == img[0, 0])
    }

    @Test func sourceOutOfBoundsThrows() async {
        let fb = Framebuffer(width: 10, height: 10)
        await expectDecodeThrows(CopyRectDecoder(), rect: RFBRect(x: 0, y: 0, width: 5, height: 5), wire: be16(6) + be16(0), framebuffer: fb)
        await expectDecodeThrows(CopyRectDecoder(), rect: RFBRect(x: 0, y: 0, width: 5, height: 5), wire: be16(0), framebuffer: fb)
    }
}

@Suite struct RRETests {
    @Test func backgroundAndSubrects() async throws {
        let fb = Framebuffer(width: 12, height: 9)
        var img = Image(width: 10, height: 7)
        for y in 0..<7 { for x in 0..<10 { img[x, y] = (10, 20, 30) } }
        var wire = be32(2) + [10, 20, 30, 0xff]
        // subrect 1: (1,1) 3x2 colour A; subrect 2: (6,2) 4x5 colour B (touches right/bottom edge)
        wire += [200, 100, 50, 0] + be16(1) + be16(1) + be16(3) + be16(2)
        wire += [1, 2, 3, 0] + be16(6) + be16(2) + be16(4) + be16(5)
        for y in 1..<3 { for x in 1..<4 { img[x, y] = (200, 100, 50) } }
        for y in 2..<7 { for x in 6..<10 { img[x, y] = (1, 2, 3) } }
        try await runDecoder(RREDecoder(), rects: [RFBRect(x: 2, y: 1, width: 10, height: 7)], wire: wire, framebuffer: fb)
        try expectMatches(fb, img, at: (2, 1))
    }

    @Test func manySubrectsAcrossBatches() async throws {
        let fb = Framebuffer(width: 100, height: 100)
        var img = Image(width: 100, height: 100)
        var wire = be32(10000) + [0, 0, 0, 0]
        for i in 0..<10000 {
            let x = i % 100, y = i / 100
            let c = (UInt8(x), UInt8(y), UInt8((x + y) & 0xff))
            img[x, y] = c
            wire += [c.0, c.1, c.2, 0] + be16(x) + be16(y) + be16(1) + be16(1)
        }
        try await runDecoder(RREDecoder(), rects: [RFBRect(x: 0, y: 0, width: 100, height: 100)], wire: wire, framebuffer: fb)
        try expectMatches(fb, img, at: (0, 0))
    }

    @Test func subrectOutsideThrows() async {
        let fb = Framebuffer(width: 20, height: 20)
        let wire = be32(1) + [0, 0, 0, 0] + [1, 1, 1, 0] + be16(8) + be16(0) + be16(3) + be16(1)
        await expectDecodeThrows(RREDecoder(), rect: RFBRect(x: 0, y: 0, width: 10, height: 10), wire: wire, framebuffer: fb)
    }

    @Test func truncatedThrows() async {
        let fb = Framebuffer(width: 20, height: 20)
        await expectDecodeThrows(RREDecoder(), rect: RFBRect(x: 0, y: 0, width: 10, height: 10), wire: be32(5) + [0, 0, 0, 0] + [1, 2], framebuffer: fb)
    }
}

@Suite struct ZlibTests {
    @Test func streamPersistsAcrossRects() async throws {
        let fb = Framebuffer(width: 40, height: 30)
        let a = noiseImage(17, 9, seed: 7)
        var b = Image(width: 17, height: 9)
        b.bgr = a.bgr   // identical content: the second rect's deflate output back-references the first
        let deflater = Deflater()
        let c1 = deflater.compress(rawWire(a))
        let c2 = deflater.compress(rawWire(b))
        #expect(c2.count < c1.count / 4, "second chunk should depend on the shared dictionary")
        let wire = be32(c1.count) + c1 + be32(c2.count) + c2
        try await runDecoder(ZlibDecoder(), rects: [RFBRect(x: 0, y: 0, width: 17, height: 9),
                                                     RFBRect(x: 20, y: 21, width: 17, height: 9)],
                             wire: wire, framebuffer: fb)
        try expectMatches(fb, a, at: (0, 0))
        try expectMatches(fb, b, at: (20, 21))

        // A fresh decoder (fresh stream) cannot decode the second chunk on its own.
        await expectDecodeThrows(ZlibDecoder(), rect: RFBRect(x: 0, y: 0, width: 17, height: 9),
                                 wire: be32(c2.count) + c2, framebuffer: fb)
    }

    @Test func malformed() async {
        let fb = Framebuffer(width: 40, height: 30)
        let img = noiseImage(4, 4, seed: 9)
        let c = Deflater().compress(rawWire(img))
        // Truncated compressed data.
        await expectDecodeThrows(ZlibDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 4), wire: be32(c.count) + c.prefix(c.count - 3), framebuffer: fb)
        // Wrong size: data for 4x4 declared as 4x3 (too much output) and 4x5 (too little).
        await expectDecodeThrows(ZlibDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 3), wire: be32(c.count) + c, framebuffer: fb)
        await expectDecodeThrows(ZlibDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 5), wire: be32(c.count) + c, framebuffer: fb)
        // Garbage.
        await expectDecodeThrows(ZlibDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 4), wire: be32(20) + [UInt8](repeating: 0xee, count: 20), framebuffer: fb)
        // Absurd length: rejected before reading.
        await expectDecodeThrows(ZlibDecoder(), rect: RFBRect(x: 0, y: 0, width: 4, height: 4), wire: be32(0x7fff_ffff), framebuffer: fb)
    }
}

@Suite struct InflateStreamTests {
    @Test func exactAndBounded() throws {
        let d = Deflater()
        let input = (0..<5000).map { UInt8($0 % 251) }
        let s = InflateStream()
        #expect(try s.inflate(d.compress(input), exactOutputSize: 5000) == input)
        let c2 = d.compress(input)
        #expect(throws: RFBError.self) { try InflateStream().inflate(c2, maxOutputSize: 100) }
        #expect(try s.inflate(c2, maxOutputSize: 5000) == input)
        #expect(try s.inflate([], maxOutputSize: 10) == [])
    }

    @Test func resetAllowsNewStream() throws {
        let s = InflateStream()
        let x = [UInt8](repeating: 7, count: 300)
        #expect(try s.inflate(Deflater().compress(x), exactOutputSize: 300) == x)
        // A brand-new deflate stream (new zlib header) fails on the old state, works after reset.
        let fresh = Deflater().compress(x)
        #expect(throws: RFBError.self) { try s.inflate(fresh, exactOutputSize: 300) }
        let s2 = InflateStream()
        _ = try s2.inflate(Deflater().compress(x), exactOutputSize: 300)
        try s2.reset()
        #expect(try s2.inflate(fresh, exactOutputSize: 300) == x)
    }
}

@Suite struct DefaultDecodersTests {
    @Test func order() {
        let encs = DefaultDecoders.factory().map(\.encoding)
        #expect(encs == [1, 7, 16, 6, 5, 2, 0])
        let only = DefaultDecoders.factory(only: [16, 0, 99, 16, -239])().map(\.encoding)
        #expect(only == [16, 0])
        // Fresh instances every call (stream state must not be shared across connections).
        #expect(DefaultDecoders.factory()[1] !== DefaultDecoders.factory()[1])
    }
}
