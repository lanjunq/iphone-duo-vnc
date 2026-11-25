import Foundation
import Testing
import zlib
import RFBBase
@testable import RFBDecoders

/// Persistent deflate stream for building wire data in tests (Z_SYNC_FLUSH after every chunk, like servers).
final class Deflater {
    private let strm = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    init(level: Int32 = Z_DEFAULT_COMPRESSION) {
        strm.initialize(to: z_stream())
        let r = deflateInit_(strm, level, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(r == Z_OK)
    }

    deinit {
        deflateEnd(strm)
        strm.deinitialize(count: 1)
        strm.deallocate()
    }

    func compress(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count + input.count / 2 + 1024)
        var produced = 0
        input.withUnsafeBufferPointer { ib in
            strm.pointee.next_in = UnsafeMutablePointer(mutating: ib.baseAddress)
            strm.pointee.avail_in = uInt(ib.count)
            repeat {
                if produced == out.count { out.append(contentsOf: repeatElement(0, count: out.count)) }
                out.withUnsafeMutableBufferPointer { ob in
                    strm.pointee.next_out = ob.baseAddress! + produced
                    strm.pointee.avail_out = uInt(ob.count - produced)
                    let r = deflate(strm, Z_SYNC_FLUSH)
                    precondition(r == Z_OK || r == Z_BUF_ERROR)
                    produced = ob.count - Int(strm.pointee.avail_out)
                }
            } while strm.pointee.avail_out == 0 || strm.pointee.avail_in > 0
        }
        return Array(out[0..<produced])
    }
}

/// Deterministic pseudo-random bytes.
struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt8 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in next() } }
}

/// Expected image (B,G,R per pixel) with helpers to compare against a framebuffer.
struct Image {
    let width: Int, height: Int
    var bgr: [UInt8]
    init(width: Int, height: Int) {
        self.width = width; self.height = height
        bgr = [UInt8](repeating: 0, count: width * height * 3)
    }
    subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        get { let i = (y * width + x) * 3; return (bgr[i], bgr[i + 1], bgr[i + 2]) }
        set { let i = (y * width + x) * 3; bgr[i] = newValue.0; bgr[i + 1] = newValue.1; bgr[i + 2] = newValue.2 }
    }
    /// Wire PIXEL (bgrx8888): B,G,R,X with a junk X byte to prove it is ignored.
    func pixel(_ x: Int, _ y: Int) -> [UInt8] { let c = self[x, y]; return [c.0, c.1, c.2, 0x5a] }
}

/// Asserts that `fb` at `origin` matches `img` within `tolerance` per channel, and alpha is 255.
func expectMatches(_ fb: Framebuffer, _ img: Image, at origin: (Int, Int), tolerance: Int = 0,
                   sourceLocation: SourceLocation = #_sourceLocation) throws {
    let px = try fb.copyPixels(RFBRect(x: origin.0, y: origin.1, width: img.width, height: img.height))
    var mismatches = 0
    var first = ""
    for y in 0..<img.height {
        for x in 0..<img.width {
            let i = (y * img.width + x) * 4
            let e = img[x, y]
            let ok = abs(Int(px[i]) - Int(e.0)) <= tolerance && abs(Int(px[i + 1]) - Int(e.1)) <= tolerance
                && abs(Int(px[i + 2]) - Int(e.2)) <= tolerance && px[i + 3] == 255
            if !ok {
                if mismatches == 0 { first = "(\(x),\(y)) got \(px[i]),\(px[i+1]),\(px[i+2]),\(px[i+3]) want \(e)" }
                mismatches += 1
            }
        }
    }
    #expect(mismatches == 0, "\(mismatches) mismatching pixels, first \(first)", sourceLocation: sourceLocation)
}

let sentinel: UInt8 = 0xA7

/// Feeds `wire` (+ a sentinel byte) through a PipeByteStream into the decoder for each rect in turn,
/// then checks that exactly the payload was consumed (the next byte read is the sentinel).
func runDecoder(_ decoder: any RectDecoder, rects: [RFBRect], wire: [UInt8], framebuffer: Framebuffer) async throws {
    let (server, client) = PipeByteStream.makePair()
    try await server.write(Data(wire + [sentinel]))
    let reader = RFBReader(stream: client, chunkSize: 997)   // odd chunk size: exercise buffer refills
    for r in rects {
        try await decoder.decode(rect: r, reader: reader, framebuffer: framebuffer)
    }
    let next = try await reader.u8()
    #expect(next == sentinel, "decoder did not consume exactly its payload")
    server.close()
}

/// Feeds `wire` and then EOF; the decode must throw (and not crash or hang).
func expectDecodeThrows(_ decoder: any RectDecoder, rect: RFBRect, wire: [UInt8], framebuffer: Framebuffer,
                        sourceLocation: SourceLocation = #_sourceLocation) async {
    let (server, client) = PipeByteStream.makePair()
    try? await server.write(Data(wire))
    server.close()   // EOF after the (possibly truncated) payload
    let reader = RFBReader(stream: client)
    await #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
        try await decoder.decode(rect: rect, reader: reader, framebuffer: framebuffer)
    }
}

func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

/// Tight compact length encoding (reference implementation for tests).
func compactLength(_ n: Int) -> [UInt8] {
    precondition(n >= 0 && n <= 4194303)
    if n < 128 { return [UInt8(n)] }
    if n < 16384 { return [UInt8(n & 0x7f) | 0x80, UInt8(n >> 7)] }
    return [UInt8(n & 0x7f) | 0x80, UInt8((n >> 7) & 0x7f) | 0x80, UInt8(n >> 14)]
}
