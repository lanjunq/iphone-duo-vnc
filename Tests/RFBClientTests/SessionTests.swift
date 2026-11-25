import Foundation
import Testing
@testable import RFBClient
import RFBBase

/// A connected client + fake server pair, handshake already done (3.8, None, 64x32 by default).
struct Session {
    let client: RFBClient
    let server: FakeServer
    let collector: EventCollector
    let info: ServerInfo

    static func start(width: Int = 64, height: Int = 32,
                      decoders: @escaping RectDecoderFactory = { [TestRawDecoder()] }) async throws -> Session {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(decoders: decoders), stream: c)
        let collector = EventCollector(client.events)
        let serverTask = Task { try await server.handshake38None(width: width, height: height) }
        let info = try await client.connect()
        _ = try await serverTask.value
        return Session(client: client, server: server, collector: collector, info: info)
    }
}

func rectHeader(_ b: inout ByteBuilder, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ enc: Int32) {
    b.u16(UInt16(x)); b.u16(UInt16(y)); b.u16(UInt16(w)); b.u16(UInt16(h)); b.i32(enc)
}

@Suite struct SessionTests {
    @Test func rawUpdateLandsInFramebufferAndRequestsIncremental() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(2)
        rectHeader(&b, 1, 2, 2, 1, RFBEncoding.raw)
        b.bytes([10, 20, 30, 0, 40, 50, 60, 0])          // B,G,R,X
        rectHeader(&b, 63, 31, 1, 1, RFBEncoding.raw)
        b.bytes([1, 2, 3, 99])
        try await sess.server.send(b)
        let req = try await sess.server.read(10)
        let want: [UInt8] = [3, 1, 0, 0, 0, 0, 0, 64, 0, 32]
        #expect(req == want)
        #expect(await sess.collector.waitFor { $0.contains(.framebufferUpdated([RFBRect(x: 1, y: 2, width: 2, height: 1),
                                                                                RFBRect(x: 63, y: 31, width: 1, height: 1)])) })
        let p1 = sess.client.framebuffer.pixel(x: 1, y: 2)
        let p2 = sess.client.framebuffer.pixel(x: 2, y: 2)
        let p3 = sess.client.framebuffer.pixel(x: 63, y: 31)
        #expect(p1.blue == 10 && p1.green == 20 && p1.red == 30)
        #expect(p2.blue == 40 && p2.green == 50 && p2.red == 60)
        #expect(p3.blue == 1 && p3.green == 2 && p3.red == 3)
        let alpha = sess.client.framebuffer.withPixels { buf, w, _ in buf[(31 * w + 63) * 4 + 3] }
        #expect(alpha == 255)
        let st = sess.client.statistics
        #expect(st.updates == 1 && st.rects == 2 && st.rectsByEncoding[0] == 2)
        #expect(st.firstUpdateAt != nil && st.serverInitAt != nil)
        #expect(st.bytesReceived > 0 && st.bytesSent > 0)
        sess.client.disconnect()
    }

    @Test func lastRectEndsUpdateEarly() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(0xffff)
        rectHeader(&b, 0, 0, 1, 1, RFBEncoding.raw); b.bytes([5, 5, 5, 0])
        rectHeader(&b, 0, 0, 0, 0, RFBEncoding.lastRect)
        b.u8(2)                                            // Bell right after: must parse as a new message
        try await sess.server.send(b)
        _ = try await sess.server.read(10)
        #expect(await sess.collector.waitFor { $0.contains(.bell) })
        #expect(sess.collector.events.first == .framebufferUpdated([RFBRect(x: 0, y: 0, width: 1, height: 1)]))
        sess.client.disconnect()
    }

    @Test func cursorPseudoEncoding() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(1)
        // 3x2 cursor, hotspot (1, 1)
        rectHeader(&b, 1, 1, 3, 2, RFBEncoding.cursor)
        for i in 0..<6 { b.bytes([UInt8(i * 10), UInt8(i * 10 + 1), UInt8(i * 10 + 2), 0]) }
        b.u8(0b1010_0000)    // row 0: pixel 0 and 2 visible
        b.u8(0b0100_0000)    // row 1: pixel 1 visible
        try await sess.server.send(b)
        _ = try await sess.server.read(10)
        #expect(await sess.collector.waitFor { $0.count >= 2 })
        guard case .cursorChanged(let cur) = sess.collector.events.first else {
            Issue.record("no cursor event: \(sess.collector.events)"); return
        }
        #expect(cur.width == 3 && cur.height == 2 && cur.hotspotX == 1 && cur.hotspotY == 1)
        let expected: [UInt8] = [0, 1, 2, 255,  0, 0, 0, 0,  20, 21, 22, 255,
                                 0, 0, 0, 0,  40, 41, 42, 255,  0, 0, 0, 0]
        #expect([UInt8](cur.bgra) == expected)
        #expect(sess.collector.events[1] == .framebufferUpdated([]))
        sess.client.disconnect()
    }

    @Test func desktopSizeResizesAndRequestsFullUpdate() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(1)
        rectHeader(&b, 0, 0, 128, 96, RFBEncoding.desktopSize)
        try await sess.server.send(b)
        let req = try await sess.server.read(10)
        let want: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 128, 0, 96]   // non-incremental, new size
        #expect(req == want)
        #expect(sess.client.framebuffer.width == 128 && sess.client.framebuffer.height == 96)
        #expect(await sess.collector.waitFor { $0.contains(.desktopResized(width: 128, height: 96)) })
        // A rect in the newly enlarged area now decodes.
        var b2 = ByteBuilder()
        b2.u8(0); b2.u8(0); b2.u16(1)
        rectHeader(&b2, 127, 95, 1, 1, RFBEncoding.raw); b2.bytes([9, 9, 9, 0])
        try await sess.server.send(b2)
        _ = try await sess.server.read(10)
        #expect(await sess.collector.waitFor { $0.contains(.framebufferUpdated([RFBRect(x: 127, y: 95, width: 1, height: 1)])) })
        sess.client.disconnect()
    }

    @Test func bellCutTextAndColourMap() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(2)                                             // Bell
        b.u8(1); b.u8(0); b.u16(0); b.u16(2); b.zeros(12)   // SetColourMapEntries, 2 colours
        b.u8(3); b.zeros(3); b.u32(6); b.bytes([0x63, 0x61, 0x66, 0xe9, 0x20, 0x21])  // "café !" Latin-1
        b.u8(2)
        try await sess.server.send(b)
        #expect(await sess.collector.waitFor { $0.count >= 3 })
        #expect(sess.collector.events == [.bell, .clipboard("café !"), .bell])
        sess.client.disconnect()
    }

    @Test func pointerKeyScrollClipboardBytes() async throws {
        let sess = try await Session.start()
        sess.client.sendPointer(x: 10, y: 20, buttons: .left)
        sess.client.sendPointer(x: -5, y: 1000, buttons: [])        // clamped to 0, 31
        sess.client.sendKey(keysym: 0xffe1, down: true)
        sess.client.sendKey(keysym: 0x41, down: false)
        sess.client.sendScroll(x: 3, y: 4, deltaX: 0, deltaY: -2, buttons: [])
        sess.client.sendScroll(x: 3, y: 4, deltaX: 1, deltaY: 0, buttons: .right)
        sess.client.sendClipboard("hé✓")
        sess.client.requestFullUpdate()
        let got = try await sess.server.read(6 + 6 + 8 + 8 + 4 * 6 + 2 * 6 + 11 + 10)
        var want: [UInt8] = []
        want += [5, 1, 0, 10, 0, 20]
        want += [5, 0, 0, 0, 0, 31]
        want += [4, 1, 0, 0, 0, 0, 0xff, 0xe1]
        want += [4, 0, 0, 0, 0, 0, 0, 0x41]
        want += [5, 8, 0, 3, 0, 4,  5, 0, 0, 3, 0, 4,  5, 8, 0, 3, 0, 4,  5, 0, 0, 3, 0, 4]
        want += [5, 0x44, 0, 3, 0, 4,  5, 4, 0, 3, 0, 4]
        want += [6, 0, 0, 0, 0, 0, 0, 3, 0x68, 0xe9, 0x3f]
        want += [3, 0, 0, 0, 0, 0, 0, 64, 0, 32]
        #expect(got == want)
        sess.client.disconnect()
    }

    @Test func sequentialInputKeepsOrder() async throws {
        let sess = try await Session.start()
        let n = 2000
        for i in 0..<n { sess.client.sendKey(keysym: UInt32(i), down: i % 2 == 0) }
        let got = try await sess.server.read(n * 8)
        for i in 0..<n {
            let m = Array(got[(i * 8)..<(i * 8 + 8)])
            let ks = UInt32(m[4]) << 24 | UInt32(m[5]) << 16 | UInt32(m[6]) << 8 | UInt32(m[7])
            #expect(m[0] == 4 && m[1] == (i % 2 == 0 ? 1 : 0) && ks == UInt32(i))
            if ks != UInt32(i) { break }
        }
        sess.client.disconnect()
    }

    @Test func concurrentInputNeverInterleaves() async throws {
        let sess = try await Session.start()
        let client = sess.client
        let perTask = 300, tasks = 8
        await withTaskGroup(of: Void.self) { g in
            for t in 0..<tasks {
                g.addTask {
                    for i in 0..<perTask {
                        if t % 2 == 0 {
                            client.sendKey(keysym: UInt32(t << 16 | i), down: true)
                        } else {
                            client.sendScroll(x: t, y: i % 32, deltaX: 0, deltaY: 1, buttons: [])  // 12 bytes
                        }
                    }
                }
            }
        }
        // Parse the byte stream message by message; each must be a whole, well-formed message, and each
        // producer's messages must appear in its own order.
        var lastKey = [Int: Int](), keyCount = 0, ptrCount = 0
        let total = (tasks / 2) * perTask * 8 + (tasks / 2) * perTask * 12
        let got = try await sess.server.read(total)
        var i = 0
        var ok = true
        while i < got.count {
            switch got[i] {
            case 4:
                let ks = Int(got[i + 4]) << 24 | Int(got[i + 5]) << 16 | Int(got[i + 6]) << 8 | Int(got[i + 7])
                let t = ks >> 16, seq = ks & 0xffff
                if let prev = lastKey[t], prev >= seq { ok = false }
                lastKey[t] = seq
                keyCount += 1
                i += 8
            case 5:
                // press + release pair must be adjacent
                if got[i + 1] != 16 || got[i + 6] != 5 || got[i + 7] != 0 { ok = false }
                ptrCount += 1
                i += 12
            default:
                ok = false
                i = got.count
            }
        }
        #expect(ok)
        #expect(keyCount == (tasks / 2) * perTask && ptrCount == (tasks / 2) * perTask)
        sess.client.disconnect()
    }

    @Test func inputIsNotBlockedByStalledReceiveLoop() async throws {
        let sess = try await Session.start()
        // Start a raw rect but send only part of its payload: the receive loop is now blocked in a read.
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(1)
        rectHeader(&b, 0, 0, 4, 4, RFBEncoding.raw)
        b.bytes([1, 2, 3])
        try await sess.server.send(b)
        try await Task.sleep(nanoseconds: 50_000_000)
        sess.client.sendKey(keysym: 0x61, down: true)
        let got = try await sess.server.read(8)
        let want: [UInt8] = [4, 1, 0, 0, 0, 0, 0, 0x61]
        #expect(got == want)
        // disconnect cancels the pending read and finishes exactly once
        sess.client.disconnect()
        sess.client.disconnect()
        #expect(await sess.collector.waitForEnd())
        #expect(sess.collector.events == [.closed(nil)])
        // Input after close is dropped silently.
        sess.client.sendKey(keysym: 1, down: true)
    }

    @Test func eofProducesClosedConnectionClosed() async throws {
        let sess = try await Session.start()
        sess.server.stream.close()
        #expect(await sess.collector.waitForEnd())
        #expect(sess.collector.events == [.closed(.connectionClosed)])
        sess.client.disconnect()     // no second .closed
        #expect(closedEvents(sess.collector.events).count == 1)
    }

    @Test func unknownMessageTypeFails() async throws {
        let sess = try await Session.start()
        try await sess.server.send([0x7f])
        #expect(await sess.collector.waitForEnd())
        #expect(sess.collector.events == [.closed(.protocolViolation("unknown server message type 127"))])
    }

    @Test func unknownEncodingFails() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(1)
        rectHeader(&b, 0, 0, 1, 1, 99)
        try await sess.server.send(b)
        #expect(await sess.collector.waitForEnd())
        #expect(sess.collector.events == [.closed(.unsupportedEncoding(99))])
    }

    @Test func outOfBoundsRectFails() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(1)
        rectHeader(&b, 60, 0, 10, 1, RFBEncoding.raw)
        try await sess.server.send(b)
        #expect(await sess.collector.waitForEnd())
        guard case .closed(.protocolViolation?) = sess.collector.events.last else {
            Issue.record("got \(sess.collector.events)"); return
        }
    }

    @Test func oversizedCursorAndCutTextFail() async throws {
        do {
            let sess = try await Session.start()
            var b = ByteBuilder()
            b.u8(0); b.u8(0); b.u16(1)
            rectHeader(&b, 0, 0, 5000, 5000, RFBEncoding.cursor)
            try await sess.server.send(b)
            #expect(await sess.collector.waitForEnd())
            guard case .closed(.protocolViolation?) = sess.collector.events.last else {
                Issue.record("got \(sess.collector.events)"); return
            }
        }
        do {
            let sess = try await Session.start()
            var b = ByteBuilder()
            b.u8(3); b.zeros(3); b.u32(0x7fff_ffff)
            try await sess.server.send(b)
            #expect(await sess.collector.waitForEnd())
            guard case .closed(.protocolViolation?) = sess.collector.events.last else {
                Issue.record("got \(sess.collector.events)"); return
            }
        }
    }

    @Test func truncatedUpdateThenEOF() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(3)
        rectHeader(&b, 0, 0, 2, 2, RFBEncoding.raw)
        b.bytes([1, 2, 3, 4, 5])
        try await sess.server.send(b)
        sess.server.stream.close()
        #expect(await sess.collector.waitForEnd())
        #expect(sess.collector.events == [.closed(.connectionClosed)])
    }

    @Test func zeroSizedDesktopAndEmptyUpdate() async throws {
        let sess = try await Session.start()
        var b = ByteBuilder()
        b.u8(0); b.u8(0); b.u16(0)                     // empty update
        try await sess.server.send(b)
        _ = try await sess.server.read(10)
        #expect(await sess.collector.waitFor { $0 == [.framebufferUpdated([])] })
        sess.client.disconnect()
    }
}
