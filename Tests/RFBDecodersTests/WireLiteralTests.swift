import Foundation
import Testing
import RFBBase
@testable import RFBDecoders

/// Decoder tests whose wire bytes are written out literally from the protocol text (RFC 6143 §7.7.4–6,
/// rfbproto.rst "Tight Encoding"), not produced by any encoder in this repository, so the decoders
/// cannot merely agree with our own mock server.
@Suite struct WireLiteralTests {
    private func px(_ fb: Framebuffer, _ x: Int, _ y: Int) -> [UInt8] {
        let p = fb.pixel(x: x, y: y)
        return [p.blue, p.green, p.red]
    }

    /// ZRLE, rect 5x2: one tile, packed palette with 3 colours = 2 bits per index, MSB first, each row
    /// padded to a whole byte (5 * 2 = 10 bits → 2 bytes per row). CPIXEL = B,G,R.
    /// Second rect 300x1 spans five tiles (64, 64, 64, 64, 44 wide): palette RLE (130 = 2 colours),
    /// `idx | 0x80` + run byte (length - 1), and a bare index for a single pixel.
    @Test func zrlePackedPaletteAndPaletteRLELiteral() async throws {
        let fb = Framebuffer(width: 320, height: 8)
        let tileA: [UInt8] = [
            3,                                   // packed palette, 3 entries
            0x10, 0x20, 0x30,  0x40, 0x50, 0x60,  0x70, 0x80, 0x90,
            0b0001_1001, 0b0000_0000,            // row 0: 0 1 2 1 | 0 + 6 pad bits
            0b1010_1010, 0b1000_0000,            // row 1: 2 2 2 2 | 2 + 6 pad bits
        ]
        // 300 = 256 + 44; 300x1 fits in 5 tiles of 64 (64,64,64,64,44), so encode per tile.
        var tilesB: [UInt8] = []
        // Tiles 0..3 are 64 pixels: palette RLE, index 1 with a run of 64 (length-1 = 63).
        for _ in 0..<4 { tilesB += [130, 1, 2, 3, 4, 5, 6, 0x81, 63] }
        // Tile 4 is 44 pixels: index 0 single, then index 1 with run 43 (length-1 = 42).
        tilesB += [130, 1, 2, 3, 4, 5, 6, 0x00, 0x81, 42]
        let d = Deflater()
        let ca = d.compress(tileA), cb = d.compress(tilesB)
        let wire = be32(ca.count) + ca + be32(cb.count) + cb
        try await runDecoder(ZRLEDecoder(), rects: [RFBRect(x: 1, y: 1, width: 5, height: 2),
                                                     RFBRect(x: 0, y: 4, width: 300, height: 1)],
                             wire: wire, framebuffer: fb)
        let c0: [UInt8] = [0x10, 0x20, 0x30], c1: [UInt8] = [0x40, 0x50, 0x60], c2: [UInt8] = [0x70, 0x80, 0x90]
        #expect([px(fb, 1, 1), px(fb, 2, 1), px(fb, 3, 1), px(fb, 4, 1), px(fb, 5, 1)] == [c0, c1, c2, c1, c0])
        for x in 1...5 { #expect(px(fb, x, 2) == c2) }
        #expect(px(fb, 0, 4) == [4, 5, 6])
        #expect(px(fb, 255, 4) == [4, 5, 6])
        #expect(px(fb, 256, 4) == [1, 2, 3])
        #expect(px(fb, 257, 4) == [4, 5, 6])
        #expect(px(fb, 299, 4) == [4, 5, 6])
        #expect(px(fb, 300, 4) == [0, 0, 0])       // untouched
    }

    /// ZRLE plain RLE run length 1 + 255 + 255 + 1 = 512: bytes 255, 255, 1 (RFC 6143 §7.7.6).
    @Test func zrlePlainRLELongRunLiteral() async throws {
        let fb = Framebuffer(width: 64, height: 8)
        let tile: [UInt8] = [128, 9, 8, 7, 255, 255, 1]   // one run covering all 64x8 = 512 pixels
        let c = Deflater().compress(tile)
        try await runDecoder(ZRLEDecoder(), rects: [RFBRect(x: 0, y: 0, width: 64, height: 8)],
                             wire: be32(c.count) + c, framebuffer: fb)
        #expect(px(fb, 0, 0) == [9, 8, 7])
        #expect(px(fb, 63, 7) == [9, 8, 7])
    }

    /// Tight from rfbproto: 0x80 = FillCompression with TPIXEL R,G,B; 0x50 | reset bit 1 = basic
    /// compression, stream 1, explicit filter; filter 1 = palette; 1 = 2 colours; 1 bit per pixel MSB
    /// first, rows padded; 2 rows of 3 pixels = 2 bytes < 12, so the data is sent uncompressed.
    @Test func tightFillAndMonoPaletteLiteral() async throws {
        let fb = Framebuffer(width: 8, height: 8)
        let wire: [UInt8] = [
            0x80, 0xAA, 0xBB, 0xCC,                       // fill rect 0: R=AA G=BB B=CC
            0x52, 0x01, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,   // stream 1 (reset bit 1), palette of 2
            0b1010_0000, 0b0100_0000,                     // row 0: 1 0 1, row 1: 0 1 0
        ]
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: 8, height: 8),
                                                      RFBRect(x: 2, y: 3, width: 3, height: 2)],
                             wire: wire, framebuffer: fb)
        let fill: [UInt8] = [0xCC, 0xBB, 0xAA]
        let p0: [UInt8] = [0x33, 0x22, 0x11], p1: [UInt8] = [0x66, 0x55, 0x44]
        #expect(px(fb, 0, 0) == fill && px(fb, 7, 7) == fill)
        #expect([px(fb, 2, 3), px(fb, 3, 3), px(fb, 4, 3)] == [p1, p0, p1])
        #expect([px(fb, 2, 4), px(fb, 3, 4), px(fb, 4, 4)] == [p0, p1, p0])
    }

    /// Hextile (RFC 6143 §7.7.4): mask 2|4|8 = background, foreground, 1 subrect; subrect byte x<<4|y,
    /// then (w-1)<<4|(h-1). Second tile mask 0 reuses both colours with no subrects (all background).
    @Test func hextileLiteral() async throws {
        let fb = Framebuffer(width: 32, height: 16)
        let wire: [UInt8] = [
            0x0E, 1, 2, 3, 0,  7, 8, 9, 0,  1,  0x21, 0x10,   // bg (1,2,3) fg (7,8,9); subrect at (2,1) 2x1
            0x00,                                              // tile 2: background only
        ]
        try await runDecoder(HextileDecoder(), rects: [RFBRect(x: 0, y: 0, width: 32, height: 16)],
                             wire: wire, framebuffer: fb)
        #expect(px(fb, 0, 0) == [1, 2, 3])
        #expect(px(fb, 2, 1) == [7, 8, 9] && px(fb, 3, 1) == [7, 8, 9])
        #expect(px(fb, 4, 1) == [1, 2, 3] && px(fb, 2, 2) == [1, 2, 3])
        #expect(px(fb, 20, 5) == [1, 2, 3])
    }
}
