import Foundation
import Testing
import CoreGraphics
import ImageIO
import zlib
import RFBBase
@testable import RFBMockServer

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// Runs `body`, failing with a timeout error after `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double = 10, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestFailure("timeout after \(seconds)s")
        }
        let r = try await group.next()!
        group.cancelAll()
        return r
    }
}

/// Persistent zlib inflate stream (independent of the server's deflate code).
final class Inflater {
    private let strm: UnsafeMutablePointer<z_stream>
    private var initialized = false

    init() {
        strm = .allocate(capacity: 1)
        strm.initialize(to: z_stream())
    }

    deinit {
        if initialized { inflateEnd(strm) }
        strm.deallocate()
    }

    func inflate(_ input: [UInt8]) throws -> [UInt8] {
        if !initialized {
            guard inflateInit_(strm, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TestFailure("inflateInit") }
            initialized = true
        }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeBufferPointer { inp in
            strm.pointee.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
            strm.pointee.avail_in = uInt(inp.count)
            while true {
                let (rc, n): (Int32, Int) = buf.withUnsafeMutableBufferPointer { ob in
                    strm.pointee.next_out = ob.baseAddress
                    strm.pointee.avail_out = uInt(ob.count)
                    let rc = zlib.inflate(strm, Z_SYNC_FLUSH)
                    return (rc, ob.count - Int(strm.pointee.avail_out))
                }
                guard rc == Z_OK || rc == Z_BUF_ERROR || rc == Z_STREAM_END else { throw TestFailure("inflate rc \(rc)") }
                out.append(contentsOf: buf[0..<n])
                if strm.pointee.avail_in == 0 && n < buf.count { break }
                if rc == Z_BUF_ERROR && n == 0 { break }
            }
        }
        return out
    }
}

/// Byte cursor over a decompressed buffer.
struct ByteCursor {
    let bytes: [UInt8]
    var pos = 0
    init(_ b: [UInt8]) { bytes = b }
    var atEnd: Bool { pos == bytes.count }
    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw TestFailure("cursor underflow") }
        defer { pos += 1 }
        return bytes[pos]
    }
    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= bytes.count else { throw TestFailure("cursor underflow (\(n))") }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
}

/// Statistics a test decoder collects about what it saw on the wire.
final class DecodeStats {
    var hextileMasks = Set<UInt8>()
    var zrleSubencodings = Set<Int>()   // 0, 1, 2 (packed palette any size), 128, 130 (palette RLE any size)
    var tightModes = Set<String>()
}

/// An independent client-side decoder for everything the mock can send.
final class TestDecoders {
    var fb: Framebuffer
    let zlibStream = Inflater()
    let zrleStream = Inflater()
    var tightStreams = [Inflater(), Inflater(), Inflater(), Inflater()]
    let stats = DecodeStats()
    var cursor: (rect: RFBRect, pixels: [UInt8], mask: [UInt8])?
    var hextileBG: [UInt8]?
    var hextileFG: [UInt8]?

    init(width: Int, height: Int) { fb = Framebuffer(width: width, height: height) }

    /// Decodes one rectangle payload read from `reader`. Returns false for LastRect.
    func decode(rect r: RFBRect, encoding: Int32, reader: RFBReader) async throws -> Bool {
        switch encoding {
        case RFBEncoding.raw:
            try fb.writeBGRX(r, try await reader.bytes(r.width * r.height * 4))
        case RFBEncoding.copyRect:
            let sx = Int(try await reader.u16()), sy = Int(try await reader.u16())
            try fb.copy(fromX: sx, y: sy, to: r)
        case RFBEncoding.hextile:
            try await decodeHextile(r, reader)
        case RFBEncoding.zlib:
            let n = Int(try await reader.u32())
            let raw = try zlibStream.inflate(try await reader.bytes(n))
            guard raw.count == r.width * r.height * 4 else { throw TestFailure("zlib size \(raw.count)") }
            try fb.writeBGRX(r, raw)
        case RFBEncoding.zrle:
            let n = Int(try await reader.u32())
            try decodeZRLE(r, try zrleStream.inflate(try await reader.bytes(n)))
        case RFBEncoding.tight:
            try await decodeTight(r, reader)
        case RFBEncoding.cursor:
            let pixels = try await reader.bytes(r.width * r.height * 4)
            let mask = try await reader.bytes((r.width + 7) / 8 * r.height)
            cursor = (r, pixels, mask)
        case RFBEncoding.desktopSize:
            fb = Framebuffer(width: r.width, height: r.height)
        case RFBEncoding.lastRect:
            return false
        default:
            throw TestFailure("unexpected encoding \(encoding)")
        }
        return true
    }

    // Hextile per RFC 6143 §7.7.4.
    func decodeHextile(_ r: RFBRect, _ reader: RFBReader) async throws {
        var ty = r.y
        while ty < r.maxY {
            let th = min(16, r.maxY - ty)
            var tx = r.x
            while tx < r.maxX {
                let tw = min(16, r.maxX - tx)
                let tile = RFBRect(x: tx, y: ty, width: tw, height: th)
                let mask = try await reader.u8()
                stats.hextileMasks.insert(mask)
                if mask & 1 != 0 {
                    try fb.writeBGRX(tile, try await reader.bytes(tw * th * 4))
                    hextileBG = nil   // strict: treat colours as undefined after a raw tile
                    hextileFG = nil
                } else {
                    if mask & 2 != 0 { hextileBG = try await reader.bytes(4) }
                    if mask & 4 != 0 { hextileFG = try await reader.bytes(4) }
                    guard let bg = hextileBG else { throw TestFailure("hextile: no background") }
                    try fb.fill(tile, blue: bg[0], green: bg[1], red: bg[2])
                    if mask & 8 != 0 {
                        let n = Int(try await reader.u8())
                        for _ in 0..<n {
                            var c: [UInt8]
                            if mask & 16 != 0 { c = try await reader.bytes(4) } else {
                                guard let fg = hextileFG else { throw TestFailure("hextile: no foreground") }
                                c = fg
                            }
                            let xy = Int(try await reader.u8()), wh = Int(try await reader.u8())
                            let sr = RFBRect(x: tx + (xy >> 4), y: ty + (xy & 15), width: (wh >> 4) + 1, height: (wh & 15) + 1)
                            guard tile.contains(sr) else { throw TestFailure("hextile subrect outside tile") }
                            try fb.fill(sr, blue: c[0], green: c[1], red: c[2])
                        }
                    }
                    if mask & 16 != 0 { hextileFG = nil }   // strict: coloured subrects leave fg undefined
                }
                tx += tw
            }
            ty += th
        }
    }

    // ZRLE per RFC 6143 §7.7.6, CPIXEL = B,G,R.
    func decodeZRLE(_ r: RFBRect, _ data: [UInt8]) throws {
        var c = ByteCursor(data)
        func cpixel() throws -> [UInt8] { try c.take(3) }
        func runLength() throws -> Int {
            var len = 1
            while true { let b = try c.u8(); len += Int(b); if b != 255 { return len } }
        }
        var ty = r.y
        while ty < r.maxY {
            let th = min(64, r.maxY - ty)
            var tx = r.x
            while tx < r.maxX {
                let tw = min(64, r.maxX - tx)
                let tile = RFBRect(x: tx, y: ty, width: tw, height: th)
                let n = tw * th
                var out = [UInt8](repeating: 0, count: n * 3)
                let sub = Int(try c.u8())
                switch sub {
                case 0:
                    stats.zrleSubencodings.insert(0)
                    out = try c.take(n * 3)
                case 1:
                    stats.zrleSubencodings.insert(1)
                    let p = try cpixel()
                    for i in 0..<n { out[i * 3] = p[0]; out[i * 3 + 1] = p[1]; out[i * 3 + 2] = p[2] }
                case 2...16:
                    stats.zrleSubencodings.insert(2)
                    var pal = [[UInt8]]()
                    for _ in 0..<sub { pal.append(try cpixel()) }
                    let bits = sub == 2 ? 1 : (sub <= 4 ? 2 : 4)
                    for y in 0..<th {
                        let row = try c.take((tw * bits + 7) / 8)
                        for x in 0..<tw {
                            let bitPos = x * bits
                            let idx = Int(row[bitPos / 8] >> UInt8(8 - bits - bitPos % 8)) & ((1 << bits) - 1)
                            guard idx < pal.count else { throw TestFailure("zrle packed index") }
                            let o = (y * tw + x) * 3
                            out[o] = pal[idx][0]; out[o + 1] = pal[idx][1]; out[o + 2] = pal[idx][2]
                        }
                    }
                case 128:
                    stats.zrleSubencodings.insert(128)
                    var i = 0
                    while i < n {
                        let p = try cpixel(); let len = try runLength()
                        guard i + len <= n else { throw TestFailure("zrle run overflow") }
                        for k in i..<(i + len) { out[k * 3] = p[0]; out[k * 3 + 1] = p[1]; out[k * 3 + 2] = p[2] }
                        i += len
                    }
                case 130...255:
                    stats.zrleSubencodings.insert(130)
                    var pal = [[UInt8]]()
                    for _ in 0..<(sub - 128) { pal.append(try cpixel()) }
                    var i = 0
                    while i < n {
                        let b = Int(try c.u8())
                        let idx = b & 127
                        let len = b & 128 != 0 ? try runLength() : 1
                        guard idx < pal.count, i + len <= n else { throw TestFailure("zrle palette run") }
                        for k in i..<(i + len) { out[k * 3] = pal[idx][0]; out[k * 3 + 1] = pal[idx][1]; out[k * 3 + 2] = pal[idx][2] }
                        i += len
                    }
                default:
                    throw TestFailure("zrle bad subencoding \(sub)")
                }
                try fb.write24(tile, out, rgbOrder: false)
                tx += tw
            }
            ty += th
        }
        guard c.atEnd else { throw TestFailure("zrle trailing bytes \(data.count - c.pos)") }
    }

    // Tight per rfbproto, TPIXEL = R,G,B.
    func compactLength(_ reader: RFBReader) async throws -> Int {
        let b0 = Int(try await reader.u8())
        var len = b0 & 0x7F
        if b0 & 0x80 != 0 {
            let b1 = Int(try await reader.u8())
            len |= (b1 & 0x7F) << 7
            if b1 & 0x80 != 0 { len |= Int(try await reader.u8()) << 14 }
        }
        return len
    }

    func tightData(_ reader: RFBReader, size: Int, stream: Int) async throws -> [UInt8] {
        if size < 12 { return try await reader.bytes(size) }
        let n = try await compactLength(reader)
        let d = try tightStreams[stream].inflate(try await reader.bytes(n))
        guard d.count == size else { throw TestFailure("tight inflated \(d.count) expected \(size)") }
        return d
    }

    func decodeTight(_ r: RFBRect, _ reader: RFBReader) async throws {
        let control = try await reader.u8()
        for i in 0..<4 where control & (1 << i) != 0 { tightStreams[i] = Inflater() }
        let n = r.width * r.height
        switch control >> 4 {
        case 0x8:
            stats.tightModes.insert("fill")
            let p = try await reader.bytes(3)
            try fb.fill(r, blue: p[2], green: p[1], red: p[0])
        case 0x9:
            stats.tightModes.insert("jpeg")
            let len = try await compactLength(reader)
            try fb.writeBGRX(r, try Self.decodeJPEG(try await reader.bytes(len), width: r.width, height: r.height))
        default:
            guard control & 0x80 == 0 else { throw TestFailure("tight bad control \(control)") }
            let stream = Int((control >> 4) & 3)
            let filter = control & 0x40 != 0 ? try await reader.u8() : 0
            switch filter {
            case 0:
                stats.tightModes.insert("copy")
                try fb.write24(r, try await tightData(reader, size: n * 3, stream: stream), rgbOrder: true)
            case 1:
                let count = Int(try await reader.u8()) + 1
                stats.tightModes.insert(count == 2 ? "mono" : "palette")
                var pal = [[UInt8]]()
                for _ in 0..<count { pal.append(try await reader.bytes(3)) }
                var out = [UInt8](repeating: 0, count: n * 3)
                if count == 2 {
                    let rowBytes = (r.width + 7) / 8
                    let d = try await tightData(reader, size: rowBytes * r.height, stream: stream)
                    for y in 0..<r.height {
                        for x in 0..<r.width {
                            let idx = Int(d[y * rowBytes + x / 8] >> UInt8(7 - x % 8)) & 1
                            out.replaceSubrange((y * r.width + x) * 3..<((y * r.width + x) * 3 + 3), with: pal[idx])
                        }
                    }
                } else {
                    let d = try await tightData(reader, size: n, stream: stream)
                    for i in 0..<n {
                        guard Int(d[i]) < count else { throw TestFailure("tight palette index") }
                        out.replaceSubrange(i * 3..<(i * 3 + 3), with: pal[Int(d[i])])
                    }
                }
                try fb.write24(r, out, rgbOrder: true)
            case 2:
                stats.tightModes.insert("gradient")
                let d = try await tightData(reader, size: n * 3, stream: stream)
                var out = [UInt8](repeating: 0, count: n * 3)
                for y in 0..<r.height {
                    for x in 0..<r.width {
                        for c in 0..<3 {
                            let left = x > 0 ? Int(out[(y * r.width + x - 1) * 3 + c]) : 0
                            let up = y > 0 ? Int(out[((y - 1) * r.width + x) * 3 + c]) : 0
                            let ul = (x > 0 && y > 0) ? Int(out[((y - 1) * r.width + x - 1) * 3 + c]) : 0
                            let pred = max(0, min(255, left + up - ul))
                            out[(y * r.width + x) * 3 + c] = UInt8((Int(d[(y * r.width + x) * 3 + c]) + pred) & 0xff)
                        }
                    }
                }
                try fb.write24(r, out, rgbOrder: true)
            default:
                throw TestFailure("tight bad filter \(filter)")
            }
        }
    }

    static func decodeJPEG(_ bytes: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw TestFailure("JPEG decode") }
        guard img.width == width, img.height == height else { throw TestFailure("JPEG size \(img.width)x\(img.height)") }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok: Bool = out.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw TestFailure("JPEG context") }
        return out
    }
}

enum ServerMessage {
    case update([(rect: RFBRect, encoding: Int32)])
    case bell
    case cutText(String)
}

/// A small RFB client used only by these tests.
final class TestClient: @unchecked Sendable {
    let stream: ByteStream
    let reader: RFBReader
    var decoders: TestDecoders!
    var serverVersion = ""
    var securityTypes: [UInt8] = []
    var width = 0, height = 0
    var name = ""
    var pixelFormat: PixelFormat?

    init(stream: ByteStream) {
        self.stream = stream
        reader = RFBReader(stream: stream)
    }

    func send(_ build: (inout ByteBuilder) -> Void) async throws {
        var b = ByteBuilder()
        build(&b)
        try await stream.write(b.data)
    }

    enum Auth { case none, vnc(String) }

    /// Runs the handshake through ServerInit. Throws `TestFailure("auth failed: reason")` on a failed result.
    func handshake(reply: String = "RFB 003.008\n", auth: Auth = .none, select: UInt8? = nil, shared: Bool = true) async throws {
        serverVersion = try await reader.string(12)
        try await stream.write(Data(reply.utf8))
        let is33 = reply.hasPrefix("RFB 003.003")
        let is37 = reply.hasPrefix("RFB 003.007")
        var type: UInt8
        if is33 {
            type = UInt8(try await reader.u32())
            securityTypes = [type]
        } else {
            let n = Int(try await reader.u8())
            if n == 0 {
                let len = Int(try await reader.u32())
                throw TestFailure("no types: " + (try await reader.string(len)))
            }
            securityTypes = try await reader.bytes(n)
            type = select ?? securityTypes[0]
            try await send { $0.u8(type) }
        }
        var expectResult = !is33 && !is37
        if type == 2 {
            let challenge = try await reader.bytes(16)
            guard case .vnc(let pw) = auth else { throw TestFailure("server wants VNC auth") }
            try await stream.write(Data(try MockVNCAuth.response(challenge: challenge, password: pw)))
            expectResult = true
        }
        if expectResult {
            let result = try await reader.u32()
            if result != 0 {
                var reason = ""
                if !is33 && !is37 { reason = try await reader.string(Int(try await reader.u32())) }
                throw TestFailure("auth failed: \(reason)")
            }
        }
        try await send { $0.u8(shared ? 1 : 0) }
        width = Int(try await reader.u16())
        height = Int(try await reader.u16())
        pixelFormat = try PixelFormat(decoding: try await reader.bytes(16))
        name = try await reader.string(Int(try await reader.u32()))
        decoders = TestDecoders(width: width, height: height)
    }

    func setPixelFormat(_ pf: PixelFormat) async throws {
        try await send { $0.u8(0); $0.zeros(3); $0.bytes(pf.encoded()) }
    }

    func setEncodings(_ list: [Int32]) async throws {
        try await send { b in b.u8(2); b.u8(0); b.u16(UInt16(list.count)); for e in list { b.i32(e) } }
    }

    func requestUpdate(incremental: Bool, rect: RFBRect? = nil) async throws {
        let r = rect ?? RFBRect(x: 0, y: 0, width: decoders.fb.width, height: decoders.fb.height)
        try await send { b in
            b.u8(3); b.u8(incremental ? 1 : 0)
            b.u16(UInt16(r.x)); b.u16(UInt16(r.y)); b.u16(UInt16(r.width)); b.u16(UInt16(r.height))
        }
    }

    func pointer(x: Int, y: Int, buttons: RFBButtonMask) async throws {
        try await send { b in b.u8(5); b.u8(buttons.rawValue); b.u16(UInt16(x)); b.u16(UInt16(y)) }
    }

    func key(_ keysym: UInt32, down: Bool) async throws {
        try await send { b in b.u8(4); b.u8(down ? 1 : 0); b.zeros(2); b.u32(keysym) }
    }

    func cutText(_ s: String) async throws {
        let bytes = Array(s.utf8)
        try await send { b in b.u8(6); b.zeros(3); b.u32(UInt32(bytes.count)); b.bytes(bytes) }
    }

    /// Reads and processes one server message.
    func readMessage() async throws -> ServerMessage {
        let type = try await reader.u8()
        switch type {
        case 0:
            try await reader.skip(1)
            let count = Int(try await reader.u16())
            var rects = [(rect: RFBRect, encoding: Int32)]()
            var i = 0
            while count == 0xFFFF || i < count {
                let r = RFBRect(x: Int(try await reader.u16()), y: Int(try await reader.u16()),
                                width: Int(try await reader.u16()), height: Int(try await reader.u16()))
                let enc = try await reader.i32()
                rects.append((r, enc))
                if !(try await decoders.decode(rect: r, encoding: enc, reader: reader)) { break }
                i += 1
            }
            return .update(rects)
        case 2:
            return .bell
        case 3:
            try await reader.skip(3)
            return .cutText(try await reader.string(Int(try await reader.u32())))
        default:
            throw TestFailure("unknown server message \(type)")
        }
    }

    func readUpdate() async throws -> [(rect: RFBRect, encoding: Int32)] {
        while true {
            if case .update(let r) = try await readMessage() { return r }
        }
    }
}

/// A connected server + test client over a pipe.
struct Harness {
    let server: MockRFBServer
    let client: TestClient
    let serveTask: Task<Void, Never>

    static func start(_ config: MockServerConfiguration) -> Harness {
        let server = MockRFBServer(configuration: config)
        let (a, b) = PipeByteStream.makePair()
        let task = Task { await server.serve(stream: a) }
        return Harness(server: server, client: TestClient(stream: b), serveTask: task)
    }

    func finish() async {
        client.stream.close()
        await serveTask.value
    }
}

/// Renders a scene into a fresh framebuffer (the expected image).
func expectedFramebuffer(_ scene: any MockScene, width: Int, height: Int) -> Framebuffer {
    let fb = Framebuffer(width: width, height: height)
    scene.render(into: fb)
    return fb
}

/// Max per-channel difference between two framebuffers of equal size (Int.max on size mismatch).
func maxDifference(_ a: Framebuffer, _ b: Framebuffer) -> Int {
    guard a.width == b.width, a.height == b.height else { return Int.max }
    let r = RFBRect(x: 0, y: 0, width: a.width, height: a.height)
    guard let pa = try? a.copyPixels(r), let pb = try? b.copyPixels(r) else { return Int.max }
    var m = 0
    for i in 0..<pa.count { m = max(m, abs(Int(pa[i]) - Int(pb[i]))) }
    return m
}

/// The server's framebuffer for the (single) active connection, copied.
func serverFramebuffer(_ server: MockRFBServer) -> Framebuffer? {
    var out: Framebuffer?
    server.withScene { _, fb in
        let copy = Framebuffer(width: fb.width, height: fb.height)
        if let px = try? fb.copyPixels(RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)) {
            try? copy.writeBGRX(RFBRect(x: 0, y: 0, width: fb.width, height: fb.height), px)
        }
        out = copy
        return []
    }
    return out
}
