import Foundation
import Testing
import CoreGraphics
import ImageIO
import RFBBase
@testable import RFBDecoders

private func noise(_ w: Int, _ h: Int, seed: UInt64) -> Image {
    var img = Image(width: w, height: h); var r = LCG(seed); img.bgr = r.bytes(w * h * 3); return img
}

/// TPIXEL stream (R,G,B) of an image.
private func tpixels(_ img: Image) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(img.width * img.height * 3)
    for y in 0..<img.height { for x in 0..<img.width { let c = img[x, y]; out += [c.2, c.1, c.0] } }
    return out
}

/// Filtered data → wire: raw when < 12 bytes, else compact length + deflate through `d`.
private func basicData(_ data: [UInt8], _ d: Deflater) -> [UInt8] {
    if data.count < 12 { return data }
    let c = d.compress(data)
    return compactLength(c.count) + c
}

/// Palette image + filtered indices (1-bit packed rows for 2 colours, else bytes).
private func paletteCase(_ w: Int, _ h: Int, colours n: Int, seed: UInt64) -> (Image, palette: [UInt8], indices: [UInt8]) {
    var r = LCG(seed)
    let pal = (0..<n).map { _ in (r.next(), r.next(), r.next()) }   // B,G,R
    var img = Image(width: w, height: h)
    var idx = [UInt8]()
    for y in 0..<h {
        var byte = 0, used = 0
        for x in 0..<w {
            let i = Int(r.next()) % n
            img[x, y] = pal[i]
            if n == 2 {
                byte = byte << 1 | i; used += 1
                if used == 8 { idx.append(UInt8(byte)); byte = 0; used = 0 }
            } else { idx.append(UInt8(i)) }
        }
        if n == 2 && used > 0 { idx.append(UInt8(byte << (8 - used))) }
    }
    var palWire = [UInt8]()
    for c in pal { palWire += [c.2, c.1, c.0] }
    return (img, palWire, idx)
}

/// Gradient filter, encoder side (rfbproto pseudo-code), on R,G,B components.
private func gradientEncode(_ img: Image) -> [UInt8] {
    let w = img.width, h = img.height
    func v(_ x: Int, _ y: Int, _ k: Int) -> Int {
        if x < 0 || y < 0 { return 0 }
        let c = img[x, y]; return Int([c.2, c.1, c.0][k])
    }
    var out = [UInt8]()
    for y in 0..<h { for x in 0..<w { for k in 0..<3 {
        let p = min(255, max(0, v(x - 1, y, k) + v(x, y - 1, k) - v(x - 1, y - 1, k)))
        out.append(UInt8((v(x, y, k) - p) & 0xff))
    } } }
    return out
}

private func smoothImage(_ w: Int, _ h: Int) -> Image {
    var img = Image(width: w, height: h)
    for y in 0..<h { for x in 0..<w {
        img[x, y] = (UInt8(40 + x * 150 / max(1, w)), UInt8(60 + y * 150 / max(1, h)), UInt8(200 - (x + y) * 100 / max(1, w + h)))
    } }
    return img
}

private func makeJPEG(_ img: Image) -> [UInt8] {
    var bgra = [UInt8]()
    for i in 0..<(img.width * img.height) { bgra += [img.bgr[i * 3], img.bgr[i * 3 + 1], img.bgr[i * 3 + 2], 255] }
    let provider = CGDataProvider(data: Data(bgra) as CFData)!
    let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return [UInt8](out as Data)
}

@Suite struct TightTests {
    @Test func compactLengthParsing() async throws {
        #expect(compactLength(10000) == [0x90, 0x4E])   // rfbproto's worked example
        let cases: [([UInt8], Int)] = [([0x00], 0), ([0x7f], 127), ([0x80, 0x01], 128), ([0x90, 0x4E], 10000),
                                       ([0xff, 0x7f], 16383), ([0x80, 0x80, 0x01], 16384),
                                       ([0xff, 0xff, 0xff], 4194303), ([0x80, 0x80, 0x80], 128 << 14)]
        for (bytes, want) in cases {
            let (s, c) = PipeByteStream.makePair()
            try await s.write(Data(bytes + [sentinel]))
            let reader = RFBReader(stream: c)
            #expect(try await TightDecoder.readCompactLength(reader) == want)
            #expect(try await reader.u8() == sentinel)
        }
    }

    @Test func fill() async throws {
        let fb = Framebuffer(width: 70, height: 70)
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 1, y: 2, width: 67, height: 65)], wire: [0x80, 10, 20, 30], framebuffer: fb)
        #expect(fb.pixel(x: 1, y: 2) == (30, 20, 10))
        #expect(fb.pixel(x: 67, y: 66) == (30, 20, 10))
        #expect(fb.pixel(x: 0, y: 2) == (0, 0, 0))
        #expect(fb.pixel(x: 68, y: 66) == (0, 0, 0))
    }

    @Test func copyFilterStreamsPersistAndInterleave() async throws {
        let fb = Framebuffer(width: 200, height: 100)
        let d0 = Deflater(), d1 = Deflater()
        let a = noise(33, 7, seed: 1), b = noise(33, 7, seed: 2)
        var c = Image(width: 33, height: 7); c.bgr = a.bgr   // repeats a: compresses via stream 0's history
        var wire = [UInt8]()
        wire += [0x00] + basicData(tpixels(a), d0)                 // stream 0, implicit copy filter
        wire += [0x50, 0x00] + basicData(tpixels(b), d1)           // stream 1, explicit filter id 0
        let cPayload = d0.compress(tpixels(c))
        #expect(cPayload.count < 100)
        wire += [0x00] + compactLength(cPayload.count) + cPayload  // stream 0 again
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: 33, height: 7),
                                                      RFBRect(x: 40, y: 0, width: 33, height: 7),
                                                      RFBRect(x: 80, y: 50, width: 33, height: 7)],
                             wire: wire, framebuffer: fb)
        try expectMatches(fb, a, at: (0, 0))
        try expectMatches(fb, b, at: (40, 0))
        try expectMatches(fb, c, at: (80, 50))
    }

    @Test func underTwelveBytesIsUncompressed() async throws {
        let fb = Framebuffer(width: 10, height: 10)
        let a = noise(3, 1, seed: 3)   // 9 bytes: raw
        let b = noise(2, 2, seed: 4)   // 12 bytes: compressed
        let d = Deflater()
        let wire = [0x00] + tpixels(a) + [0x00] + basicData(tpixels(b), d)
        #expect(wire.count != 1 + 9 + 1 + 12)
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: 3, height: 1), RFBRect(x: 5, y: 5, width: 2, height: 2)],
                             wire: wire, framebuffer: fb)
        try expectMatches(fb, a, at: (0, 0))
        try expectMatches(fb, b, at: (5, 5))
    }

    @Test(arguments: [(13, 5, 2), (20, 7, 2), (1, 1, 2), (9, 4, 5), (2, 5, 3), (64, 33, 256), (17, 3, 1), (8, 8, 2)])
    func paletteFilter(w: Int, h: Int, colours: Int) async throws {
        let (img, pal, idx) = paletteCase(w, h, colours: colours, seed: UInt64(w * 100 + h))
        let d = Deflater()
        let wire = [0x60, 0x01, UInt8(colours - 1)] + pal + basicData(idx, d)   // stream 2, palette filter
        let fb = Framebuffer(width: w + 3, height: h + 1)
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 3, y: 1, width: w, height: h)], wire: wire, framebuffer: fb)
        try expectMatches(fb, img, at: (3, 1))
    }

    @Test(arguments: [(23, 11), (1, 1), (2, 2), (64, 40), (5, 1), (1, 9)])
    func gradientFilter(w: Int, h: Int) async throws {
        // Noise exercises clamping in both directions; a smooth image exercises typical prediction.
        for img in [noise(w, h, seed: UInt64(w + h)), smoothImage(w, h)] {
            let d = Deflater()
            let wire = [0x70, 0x02] + basicData(gradientEncode(img), d)   // stream 3, gradient filter
            let fb = Framebuffer(width: w, height: h)
            try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: w, height: h)], wire: wire, framebuffer: fb)
            try expectMatches(fb, img, at: (0, 0))
        }
    }

    @Test func compactLengthTwoAndThreeBytes() async throws {
        let fb = Framebuffer(width: 120, height: 80)
        let small = noise(50, 10, seed: 5)    // ~1.5 KB compressed: 2-byte length
        let big = noise(100, 60, seed: 6)     // ~18 KB compressed: 3-byte length
        let d = Deflater()
        let s = basicData(tpixels(small), d), b = basicData(tpixels(big), d)
        #expect(s[0] & 0x80 != 0 && s[1] & 0x80 == 0)
        #expect(b[0] & 0x80 != 0 && b[1] & 0x80 != 0)
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: 50, height: 10), RFBRect(x: 20, y: 20, width: 100, height: 60)],
                             wire: [0x00] + s + [0x00] + b, framebuffer: fb)
        try expectMatches(fb, small, at: (0, 0))
        try expectMatches(fb, big, at: (20, 20))
    }

    @Test func resetBits() async throws {
        let fb = Framebuffer(width: 100, height: 100)
        let a = noise(10, 10, seed: 7), b = noise(10, 10, seed: 8), c = noise(10, 10, seed: 9)
        var wire = [UInt8]()
        wire += [0x20] + basicData(tpixels(a), Deflater())          // stream 2, deflater #1
        wire += [0x24] + basicData(tpixels(b), Deflater())          // reset stream 2, new deflater #2
        wire += [0x88, 1, 2, 3]                                     // fill that also resets stream 3
        wire += [0x30] + basicData(tpixels(c), Deflater())          // stream 3, new deflater #3
        wire += [0x8f, 4, 5, 6]                                     // fill resetting all four streams
        wire += [0x30] + basicData(tpixels(a), Deflater())          // stream 3 fresh again
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: 10, height: 10), RFBRect(x: 10, y: 0, width: 10, height: 10),
                                                      RFBRect(x: 20, y: 0, width: 5, height: 5), RFBRect(x: 30, y: 0, width: 10, height: 10),
                                                      RFBRect(x: 40, y: 0, width: 5, height: 5), RFBRect(x: 50, y: 0, width: 10, height: 10)],
                             wire: wire, framebuffer: fb)
        try expectMatches(fb, a, at: (0, 0))
        try expectMatches(fb, b, at: (10, 0))
        #expect(fb.pixel(x: 20, y: 0) == (3, 2, 1))
        try expectMatches(fb, c, at: (30, 0))
        try expectMatches(fb, a, at: (50, 0))

        // Without the reset bit, a new deflate stream on an already-used inflate stream must fail.
        let dec = TightDecoder()
        let fb2 = Framebuffer(width: 20, height: 20)
        try await runDecoder(dec, rects: [RFBRect(x: 0, y: 0, width: 10, height: 10)], wire: [0x20] + basicData(tpixels(a), Deflater()), framebuffer: fb2)
        await expectDecodeThrows(dec, rect: RFBRect(x: 0, y: 0, width: 10, height: 10), wire: [0x20] + basicData(tpixels(b), Deflater()), framebuffer: fb2)
    }

    @Test func withoutZlib() async throws {
        let fb = Framebuffer(width: 40, height: 40)
        let a = noise(6, 5, seed: 10)
        let (p, pal, idx) = paletteCase(11, 3, colours: 2, seed: 11)
        let wire = [0xA0] + tpixels(a) + [0xE0, 0x01, 0x01] + pal + idx
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 0, y: 0, width: 6, height: 5), RFBRect(x: 10, y: 10, width: 11, height: 3)],
                             wire: wire, framebuffer: fb)
        try expectMatches(fb, a, at: (0, 0))
        try expectMatches(fb, p, at: (10, 10))
    }

    @Test(arguments: [(64, 48), (37, 13), (1, 1)])
    func jpeg(w: Int, h: Int) async throws {
        let img = smoothImage(w, h)
        let j = makeJPEG(img)
        let fb = Framebuffer(width: w + 10, height: h + 10)
        try await runDecoder(TightDecoder(), rects: [RFBRect(x: 10, y: 10, width: w, height: h)],
                             wire: [0x9f] + compactLength(j.count) + j, framebuffer: fb)   // also resets all streams
        try expectMatches(fb, img, at: (10, 10), tolerance: 12)
    }

    @Test func malformed() async {
        let fb = Framebuffer(width: 64, height: 64)
        let r = RFBRect(x: 0, y: 0, width: 4, height: 4)
        for control: UInt8 in [0xB0, 0xC0, 0xD0, 0xF0] {
            await expectDecodeThrows(TightDecoder(), rect: r, wire: [control] + [UInt8](repeating: 0, count: 64), framebuffer: fb)
        }
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x40, 0x03] + [UInt8](repeating: 0, count: 64), framebuffer: fb)  // filter 3
        // Palette index 3 with only 3 colours (8-bit indices, 16 bytes → compressed).
        let idx = [UInt8](repeating: 3, count: 16), c = Deflater().compress(idx)
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x40, 0x01, 0x02, 1,1,1, 2,2,2, 3,3,3] + compactLength(c.count) + c, framebuffer: fb)
        // Truncated: compact length promises more than is sent; compact length itself cut short.
        let d = Deflater().compress([UInt8](repeating: 9, count: 48))
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x00] + compactLength(d.count + 5) + d, framebuffer: fb)
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x00, 0x85], framebuffer: fb)
        // Zlib data inflating to the wrong size (rect 4x4 needs 48 bytes; send 45).
        let short = Deflater().compress([UInt8](repeating: 9, count: 45))
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x00] + compactLength(short.count) + short, framebuffer: fb)
        // Garbage zlib.
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x00, 10] + [UInt8](repeating: 0xcd, count: 10), framebuffer: fb)
        // JPEG: garbage, zero length, wrong dimensions.
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x90, 20] + [UInt8](repeating: 0x42, count: 20), framebuffer: fb)
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x90, 0], framebuffer: fb)
        let j = makeJPEG(smoothImage(8, 8))
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x90] + compactLength(j.count) + j, framebuffer: fb)
        // Truncated fill, out-of-bounds rect.
        await expectDecodeThrows(TightDecoder(), rect: r, wire: [0x80, 1, 2], framebuffer: fb)
        await expectDecodeThrows(TightDecoder(), rect: RFBRect(x: 62, y: 0, width: 4, height: 4), wire: [0x80, 1, 2, 3], framebuffer: fb)
    }
}
