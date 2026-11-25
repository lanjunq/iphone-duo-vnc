import Foundation
import Testing
@testable import RFBMockServer
import RFBBase

/// Builds a framebuffer from a pixel function (r, g, b).
func makeImage(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Framebuffer {
    let fb = Framebuffer(width: w, height: h)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let (r, g, b) = f(x, y)
            let i = (y * w + x) * 4
            px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = 255
        }
    }
    try! fb.writeBGRX(RFBRect(x: 0, y: 0, width: w, height: h), px)
    return fb
}

/// Feeds encoded rectangles' payloads through a pipe into `decoders`.
func decode(_ rects: [MockEncodedRect], into decoders: TestDecoders) async throws {
    let (a, b) = PipeByteStream.makePair()
    var all = Data()
    for r in rects { all.append(r.payload) }
    all.append(0xEE)   // sentinel: decoders must consume exactly the payload
    try await a.write(all)
    let reader = RFBReader(stream: b)
    for r in rects { _ = try await decoders.decode(rect: r.rect, encoding: r.encoding, reader: reader) }
    let sentinel = try await reader.u8()
    #expect(sentinel == 0xEE)
}

func roundTrip(_ enc: any MockRectEncoder, _ fb: Framebuffer, rects: [RFBRect]? = nil) async throws -> TestDecoders {
    let d = TestDecoders(width: fb.width, height: fb.height)
    for r in rects ?? [RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)] {
        try await decode(try enc.encode(r, from: fb), into: d)
    }
    return d
}

let noise: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in
    let v = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663)) &* 2_654_435_761
    return (UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff))
}

@Suite struct EncoderTests {
    @Test func tightCompactLength() throws {
        #expect(try MockTightEncoder.compactLength(0) == [0])
        #expect(try MockTightEncoder.compactLength(127) == [0x7F])
        #expect(try MockTightEncoder.compactLength(128) == [0x80, 0x01])
        #expect(try MockTightEncoder.compactLength(16383) == [0xFF, 0x7F])
        #expect(try MockTightEncoder.compactLength(16384) == [0x80, 0x80, 0x01])
        #expect(try MockTightEncoder.compactLength(4_194_303) == [0xFF, 0xFF, 0xFF])
        #expect(throws: RFBError.self) { try MockTightEncoder.compactLength(4_194_304) }
    }

    @Test func zrleRunLengthBytes() {
        func rl(_ n: Int) -> [UInt8] { var o = [UInt8](); MockZRLEEncoder.appendRunLength(n, to: &o); return o }
        #expect(rl(1) == [0])
        #expect(rl(255) == [254])
        #expect(rl(256) == [255, 0])
        #expect(rl(510) == [255, 254])
        #expect(rl(4096) == [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 15])
    }

    @Test func rawExactBytes() throws {
        let fb = makeImage(2, 1) { x, _ in x == 0 ? (1, 2, 3) : (250, 251, 252) }
        let r = try MockRawEncoder().encode(RFBRect(x: 0, y: 0, width: 2, height: 1), from: fb)
        #expect(r.count == 1)
        #expect([UInt8](r[0].payload) == [3, 2, 1, 0, 252, 251, 250, 0])
        #expect([UInt8](r[0].wireBytes.prefix(12)) == [0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0])
    }

    @Test func tightFillExactBytes() throws {
        let fb = makeImage(40, 30) { _, _ in (10, 20, 30) }
        let r = try MockTightEncoder().encode(RFBRect(x: 0, y: 0, width: 40, height: 30), from: fb)
        #expect(r.count == 1)
        #expect([UInt8](r[0].payload) == [0x80, 10, 20, 30])   // TPIXEL = R, G, B
    }

    @Test func tightSmallDataIsUncompressed() throws {
        // 2x1 copy filter = 6 bytes of data < 12: sent raw, no length.
        let fb = makeImage(2, 1) { x, _ in x == 0 ? (1, 2, 3) : (4, 5, 6) }
        let enc = MockTightEncoder(forcedMode: .copy)
        let r = try enc.encode(RFBRect(x: 0, y: 0, width: 2, height: 1), from: fb)
        #expect([UInt8](r[0].payload) == [0x00, 1, 2, 3, 4, 5, 6])
        // 2-colour palette 8x1 = 1 byte of index data.
        let fb2 = makeImage(8, 1) { x, _ in x % 3 == 0 ? (255, 0, 0) : (0, 0, 255) }
        let r2 = try MockTightEncoder().encode(RFBRect(x: 0, y: 0, width: 8, height: 1), from: fb2)
        // control: explicit filter, stream 1; filter 1; 2 colours; palette (first seen = red); bits 1 = blue.
        #expect([UInt8](r2[0].payload) == [0x50, 0x01, 0x01, 255, 0, 0, 0, 0, 255, 0b0110_1101])
    }

    @Test(arguments: [MockTightEncoder.Mode.copy, .gradient, .palette, .fill])
    func tightForcedModesLossless(_ mode: MockTightEncoder.Mode) async throws {
        let fb: Framebuffer
        switch mode {
        case .fill: fb = makeImage(37, 13) { _, _ in (7, 8, 9) }
        case .palette: fb = makeImage(37, 13) { x, y in [(255, 0, 0), (0, 255, 0), (0, 0, 255), (9, 9, 9), (200, 100, 50)][(x * 3 + y) % 5] }
        case .gradient: fb = makeImage(300, 70) { x, y in (UInt8(x % 256), UInt8((y * 3) % 256), UInt8((x + y) % 256)) }
        default: fb = makeImage(300, 70, noise)
        }
        let enc = MockTightEncoder(forcedMode: mode)
        let d = try await roundTrip(enc, fb)
        #expect(maxDifference(d.fb, fb) == 0)
        #expect(enc.lastModes.allSatisfy { $0 == mode })
    }

    @Test func tightMonoOddWidthAndStreamPersistence() async throws {
        let fb = makeImage(37, 21) { x, y in (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
        let enc = MockTightEncoder()
        let d = try await roundTrip(enc, fb, rects: [RFBRect(x: 0, y: 0, width: 37, height: 10), RFBRect(x: 0, y: 10, width: 37, height: 11)])
        #expect(maxDifference(d.fb, fb) == 0)
        #expect(d.stats.tightModes == ["mono"])
    }

    @Test func tightSplitsLargeRects() async throws {
        let fb = makeImage(600, 300, noise)
        let enc = MockTightEncoder()
        let rects = try enc.encode(RFBRect(x: 0, y: 0, width: 600, height: 300), from: fb)
        #expect(rects.allSatisfy { $0.rect.width <= 256 && $0.rect.height <= 256 })
        #expect(rects.reduce(0) { $0 + $1.rect.width * $1.rect.height } == 600 * 300)
        let d = TestDecoders(width: 600, height: 300)
        try await decode(rects, into: d)
        #expect(maxDifference(d.fb, fb) == 0)
    }

    @Test func tightJPEG() async throws {
        let fb = makeImage(120, 90) { x, y in (UInt8(x * 2), UInt8(y * 2), 128) }
        let enc = MockTightEncoder(jpegQuality: 9, forcedMode: .jpeg)
        let rects = try enc.encode(RFBRect(x: 0, y: 0, width: 120, height: 90), from: fb)
        let p = [UInt8](rects[0].payload)
        #expect(p[0] == 0x90)
        // JPEG SOI after the compact length.
        let lenBytes = p[1] & 0x80 == 0 ? 1 : (p[2] & 0x80 == 0 ? 2 : 3)
        #expect(p[1 + lenBytes] == 0xFF && p[2 + lenBytes] == 0xD8)
        let d = TestDecoders(width: 120, height: 90)
        try await decode(rects, into: d)
        #expect(maxDifference(d.fb, fb) <= 16)
    }

    @Test(arguments: [MockZRLEEncoder.ForcedMode.raw, .solid, .packedPalette, .plainRLE, .paletteRLE])
    func zrleForcedModes(_ mode: MockZRLEEncoder.ForcedMode) async throws {
        let w = 131, h = 70   // crosses 64-pixel tile boundaries with partial tiles
        let images: [Framebuffer]
        switch mode {
        case .solid: images = [makeImage(w, h) { _, _ in (1, 2, 3) }]
        case .packedPalette, .paletteRLE:
            images = [2, 3, 4, 5, 16].map { n in makeImage(w, h) { x, y in let k = UInt8((x / 3 + y) % n); return (k * 15, 255 - k * 9, k) } }
        case .plainRLE: images = [makeImage(w, h) { x, y in (UInt8(x / 20 * 30), UInt8(y), 7) }]
        case .raw: images = [makeImage(w, h, noise)]
        }
        for fb in images {
            let d = try await roundTrip(MockZRLEEncoder(forcedMode: mode), fb)
            #expect(maxDifference(d.fb, fb) == 0)
            let expectedSub: Int = [.raw: 0, .solid: 1, .packedPalette: 2, .plainRLE: 128, .paletteRLE: 130][mode]!
            #expect(d.stats.zrleSubencodings == [expectedSub])
        }
    }

    @Test func zrleLongRunsAndPersistence() async throws {
        // Long runs (> 255) need multi-byte lengths; two rects share one zlib stream.
        let fb = makeImage(200, 200) { x, y in y < 100 ? (10, 10, 10) : (x < 150 ? (200, 0, 0) : (0, 200, 0)) }
        let enc = MockZRLEEncoder(forcedMode: .plainRLE)
        let d = try await roundTrip(enc, fb, rects: [RFBRect(x: 0, y: 0, width: 200, height: 100), RFBRect(x: 0, y: 100, width: 200, height: 100)])
        #expect(maxDifference(d.fb, fb) == 0)
    }

    @Test func zrleSolidTileBytes() throws {
        let fb = makeImage(10, 10) { _, _ in (0x11, 0x22, 0x33) }
        let r = try MockZRLEEncoder().encode(RFBRect(x: 0, y: 0, width: 10, height: 10), from: fb)
        let p = [UInt8](r[0].payload)
        let len = Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])
        #expect(len == p.count - 4)
        let raw = try Inflater().inflate(Array(p[4...]))
        #expect(raw == [1, 0x33, 0x22, 0x11])   // solid, CPIXEL = B, G, R
    }

    @Test func zrleAutoPicksSmallest() async throws {
        let fb = makeImage(64, 64) { x, y in (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
        let d = try await roundTrip(MockZRLEEncoder(), fb)
        #expect(d.stats.zrleSubencodings == [2])   // checkerboard: packed palette, 1 bit/pixel
        #expect(maxDifference(d.fb, fb) == 0)
    }

    @Test func hextileImages() async throws {
        let images = [
            makeImage(33, 17) { _, _ in (5, 6, 7) },
            makeImage(33, 17) { x, y in (x / 4 + y / 3) % 2 == 0 ? (0, 0, 0) : (255, 255, 0) },
            makeImage(50, 40) { x, y in [(255, 0, 0), (0, 255, 0), (0, 0, 255)][(x / 5 + y / 7) % 3] },
            makeImage(50, 40, noise),
            // Raw tiles next to solid / subrect tiles (background must be re-sent after a raw tile).
            makeImage(64, 32) { x, y in x / 16 % 2 == 0 ? noise(x, y) : (x < 48 ? (9, 9, 9) : ((x + y) % 5 == 0 ? (1, 1, 1) : (9, 9, 9))) },
        ]
        for fb in images {
            let d = try await roundTrip(MockHextileEncoder(), fb)
            #expect(maxDifference(d.fb, fb) == 0)
        }
    }

    @Test func hextileSolidTileBytes() throws {
        let fb = makeImage(32, 16) { _, _ in (1, 2, 3) }
        let r = try MockHextileEncoder().encode(RFBRect(x: 0, y: 0, width: 32, height: 16), from: fb)
        // First tile specifies the background; second tile inherits it (mask 0).
        #expect([UInt8](r[0].payload) == [2, 3, 2, 1, 0, 0])
    }

    @Test func zlibPersistentStream() async throws {
        let fb = makeImage(90, 60, noise)
        let d = try await roundTrip(MockZlibEncoder(), fb, rects: [RFBRect(x: 0, y: 0, width: 90, height: 30), RFBRect(x: 0, y: 30, width: 90, height: 30)])
        #expect(maxDifference(d.fb, fb) == 0)
    }

    @Test func subRectangleOffsets() async throws {
        // Encoding a rect that does not start at the origin must read the right pixels.
        let fb = makeImage(100, 80, noise)
        let r = RFBRect(x: 17, y: 23, width: 41, height: 19)
        let encoders: [any MockRectEncoder] = [MockRawEncoder(), MockHextileEncoder(), MockZlibEncoder(), MockZRLEEncoder(), MockTightEncoder()]
        for e in encoders {
            let d = try await roundTrip(e, fb, rects: [r])
            let got = try d.fb.copyPixels(r), want = try fb.copyPixels(r)
            #expect(got == want)
        }
    }

    @Test func outOfBoundsRectThrows() {
        let fb = Framebuffer(width: 10, height: 10)
        let encoders: [any MockRectEncoder] = [MockRawEncoder(), MockHextileEncoder(), MockZlibEncoder(), MockZRLEEncoder(), MockTightEncoder()]
        for e in encoders {
            #expect(throws: RFBError.self) { try e.encode(RFBRect(x: 5, y: 5, width: 10, height: 10), from: fb) }
        }
    }

    @Test func cursorEncoding() {
        let c = RFBCursor(width: 9, height: 2, hotspotX: 3, hotspotY: 1,
                          bgra: Data((0..<18).flatMap { i -> [UInt8] in [UInt8(i), 0, 0, i % 2 == 0 ? 255 : 0] }))
        let e = MockSession.encodeCursor(c)
        #expect(e.rect == RFBRect(x: 3, y: 1, width: 9, height: 2))
        let p = [UInt8](e.payload)
        #expect(p.count == 9 * 2 * 4 + 2 * 2)
        // Row 0: pixels 0,2,4,6,8 opaque -> 1010 1010 1(000 0000); row 1 (indices 9...17): 10,12,14,16 -> pixels 1,3,5,7.
        #expect(Array(p.suffix(4)) == [0b1010_1010, 0b1000_0000, 0b0101_0101, 0b0000_0000])
    }
}
