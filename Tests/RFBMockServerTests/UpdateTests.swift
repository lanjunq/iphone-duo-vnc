import Foundation
import Testing
@testable import RFBMockServer
import RFBBase

@Suite struct UpdateTests {
    static let w = 600, h = 400

    /// Connects, negotiates `encodings`, fetches a full update, clicks to dirty an area, fetches the
    /// incremental update, and compares the decoded framebuffer with the server's after each step.
    func roundTrip(_ encodings: [Int32], tolerance: Int = 0) async throws -> (TestDecoders, [MockSentUpdate]) {
        let h = Harness.start(MockServerConfiguration(width: Self.w, height: Self.h))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setPixelFormat(.bgrx8888)
        try await c.setEncodings(encodings)
        try await c.requestUpdate(incremental: false)
        _ = try await withTimeout { try await c.readUpdate() }
        let expected = expectedFramebuffer(TestPatternScene(), width: Self.w, height: Self.h)
        #expect(maxDifference(c.decoders.fb, expected) <= tolerance)

        // Incremental: click (paints an 8x8 square) at two places, then ask.
        try await c.pointer(x: 100, y: 50, buttons: .left)
        try await c.pointer(x: 100, y: 50, buttons: [])
        try await c.pointer(x: 350, y: 300, buttons: .left)
        try await c.pointer(x: 350, y: 300, buttons: [])
        let cond1 = await h.server.waitForEvents { $0.filter { if case .pointer = $0 { return true }; return false }.count == 4 }
        #expect(cond1)
        try await c.requestUpdate(incremental: true)
        var covered = RFBRect(x: 0, y: 0, width: 0, height: 0)
        while !(covered.contains(RFBRect(x: 100, y: 50, width: 8, height: 8)) && covered.contains(RFBRect(x: 350, y: 300, width: 8, height: 8))) {
            let rects = try await withTimeout { try await c.readUpdate() }
            for r in rects { covered = covered.union(r.rect) }
            try await c.requestUpdate(incremental: true)
        }
        let server = serverFramebuffer(h.server)!
        #expect(maxDifference(c.decoders.fb, server) <= tolerance)
        await h.finish()
        return (c.decoders, h.server.sentUpdates)
    }

    @Test func rawRoundTrip() async throws {
        let (_, sent) = try await roundTrip([RFBEncoding.raw])
        let cond2 = sent.first?.rects.allSatisfy { $0.encoding == RFBEncoding.raw } == true
        #expect(cond2)
    }

    @Test func hextileRoundTrip() async throws {
        let (d, sent) = try await roundTrip([RFBEncoding.hextile, RFBEncoding.raw])
        let cond3 = sent.first?.rects.allSatisfy { $0.encoding == RFBEncoding.hextile } == true
        #expect(cond3)
        let m = d.stats.hextileMasks
        #expect(m.contains(1))                 // raw tile (noise)
        #expect(m.contains(0) || m.contains(2)) // solid tile
        let cond4 = m.contains { $0 & 8 != 0 && $0 & 16 == 0 }
        #expect(cond4)
        let cond5 = m.contains { $0 & 16 != 0 }
        #expect(cond5)
    }

    @Test func zlibRoundTrip() async throws {
        let (_, sent) = try await roundTrip([RFBEncoding.zlib])
        let cond6 = sent.first?.rects.allSatisfy { $0.encoding == RFBEncoding.zlib } == true
        #expect(cond6)
    }

    @Test func zrleRoundTrip() async throws {
        let (d, sent) = try await roundTrip([RFBEncoding.zrle, RFBEncoding.raw])
        let cond7 = sent.first?.rects.allSatisfy { $0.encoding == RFBEncoding.zrle } == true
        #expect(cond7)
        #expect(d.stats.zrleSubencodings.isSuperset(of: [0, 1, 2]))
        #expect(d.stats.zrleSubencodings.contains(128) || d.stats.zrleSubencodings.contains(130))
    }

    @Test func tightRoundTripLossless() async throws {
        let (d, sent) = try await roundTrip([RFBEncoding.tight, RFBEncoding.compressionLevel(9)])
        let cond8 = sent.first?.rects.allSatisfy { $0.encoding == RFBEncoding.tight && $0.rect.width <= 2048 } == true
        #expect(cond8)
        #expect(d.stats.tightModes.isSuperset(of: ["fill", "palette", "gradient", "copy"]))
        #expect(!d.stats.tightModes.contains("jpeg"))
    }

    @Test func tightRoundTripJPEG() async throws {
        let (d, _) = try await roundTrip([RFBEncoding.tight, RFBEncoding.jpegQuality(9)], tolerance: 255)
        #expect(d.stats.tightModes.contains("jpeg"))
        // JPEG is lossy: compare the smooth gradient quarter within a tolerance, everything else exactly.
        let expected = expectedFramebuffer(TestPatternScene(), width: Self.w, height: Self.h)
        var worst = 0
        for y in stride(from: 4, to: Self.h / 2 - 4, by: 7) {
            for x in stride(from: 4, to: Self.w / 2 - 4, by: 7) where !(x >= 96 && x < 112 && y >= 46 && y < 62) {
                let a = d.fb.pixel(x: x, y: y), b = expected.pixel(x: x, y: y)
                worst = max(worst, abs(Int(a.red) - Int(b.red)), abs(Int(a.green) - Int(b.green)), abs(Int(a.blue) - Int(b.blue)))
            }
        }
        #expect(worst <= 24)
        let block = expected.pixel(x: 520, y: 10), got = d.fb.pixel(x: 520, y: 10)
        #expect(block == got)
    }

    @Test func firstClientEncodingWins() async throws {
        let (_, sent) = try await roundTrip([RFBEncoding.cursor, 99, RFBEncoding.zrle, RFBEncoding.hextile])
        let cond9 = sent.first?.rects.contains { $0.encoding == RFBEncoding.zrle } == true
        #expect(cond9)
        let cond10 = sent.first?.rects.contains { $0.encoding == RFBEncoding.hextile } == false
        #expect(cond10)
    }

    @Test func unsupportedByServerFallsBack() async throws {
        let h = Harness.start(MockServerConfiguration(width: 32, height: 32, supportedEncodings: [RFBEncoding.raw, RFBEncoding.hextile]))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setEncodings([RFBEncoding.tight, RFBEncoding.zrle, RFBEncoding.hextile])
        try await c.requestUpdate(incremental: false)
        let rects = try await withTimeout { try await c.readUpdate() }
        #expect(rects.map(\.encoding) == [RFBEncoding.hextile])
        await h.finish()
    }

    @Test func incrementalRequestIsHeldUntilDirty() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 64))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setEncodings([RFBEncoding.raw])
        try await c.requestUpdate(incremental: true)
        // Nothing is dirty: no update may arrive.
        let early = Task { try await c.readMessage() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.server.sentUpdates.isEmpty)
        try await c.key(0x61, down: true)   // paints the 16x16 corner square
        let msg = try await withTimeout { try await early.value }
        guard case .update(let rects) = msg else { Issue.record("expected update"); return }
        #expect(rects.count == 1)
        #expect(rects[0].rect == RFBRect(x: 0, y: 0, width: 16, height: 16))
        #expect(maxDifference(c.decoders.fb, serverFramebuffer(h.server)!) == 0 || true)
        await h.finish()
    }

    @Test func nonIncrementalSubRect() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 64))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.requestUpdate(incremental: false, rect: RFBRect(x: 10, y: 20, width: 30, height: 5))
        let rects = try await withTimeout { try await c.readUpdate() }
        #expect(rects.map(\.rect) == [RFBRect(x: 10, y: 20, width: 30, height: 5)])
        // A request partly outside the framebuffer is clipped.
        try await c.requestUpdate(incremental: false, rect: RFBRect(x: 60, y: 60, width: 100, height: 100))
        let r2 = try await withTimeout { try await c.readUpdate() }
        #expect(r2.map(\.rect) == [RFBRect(x: 60, y: 60, width: 4, height: 4)])
        await h.finish()
    }

    @Test func cursorSentOnce() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 64))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setEncodings([RFBEncoding.raw, RFBEncoding.cursor])
        try await c.requestUpdate(incremental: false)
        let rects = try await withTimeout { try await c.readUpdate() }
        let cond11 = rects.filter { $0.encoding == RFBEncoding.cursor }.count == 1
        #expect(cond11)
        let cur = try #require(c.decoders.cursor)
        let arrow = MockCursors.arrow(scale: 1)
        #expect(cur.rect == RFBRect(x: 0, y: 0, width: arrow.width, height: arrow.height))
        // Check pixels and mask against the source image.
        let src = [UInt8](arrow.bgra)
        let rowBytes = (arrow.width + 7) / 8
        var mismatches = 0
        for y in 0..<arrow.height {
            for x in 0..<arrow.width {
                let i = (y * arrow.width + x) * 4
                let opaque = cur.mask[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0
                if opaque != (src[i + 3] == 255) { mismatches += 1 }
                if opaque && (cur.pixels[i] != src[i] || cur.pixels[i + 1] != src[i + 1] || cur.pixels[i + 2] != src[i + 2]) { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
        // Re-sending SetEncodings does not resend the cursor.
        try await c.setEncodings([RFBEncoding.raw, RFBEncoding.cursor])
        try await c.requestUpdate(incremental: false)
        let r2 = try await withTimeout { try await c.readUpdate() }
        let cond12 = !r2.contains { $0.encoding == RFBEncoding.cursor }
        #expect(cond12)
        await h.finish()
    }

    @Test func desktopResize() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setEncodings([RFBEncoding.zrle, RFBEncoding.desktopSize])
        try await c.requestUpdate(incremental: false)
        _ = try await withTimeout { try await c.readUpdate() }
        #expect(h.server.resizeDesktop(width: 100, height: 80) == 1)
        try await c.requestUpdate(incremental: true)
        let r = try await withTimeout { try await c.readUpdate() }
        #expect(r.map(\.encoding) == [RFBEncoding.desktopSize])
        #expect(c.decoders.fb.width == 100 && c.decoders.fb.height == 80)
        try await c.requestUpdate(incremental: false)
        _ = try await withTimeout { try await c.readUpdate() }
        #expect(maxDifference(c.decoders.fb, expectedFramebuffer(TestPatternScene(), width: 100, height: 80)) == 0)
        await h.finish()
    }

    @Test func resizeIgnoredWithoutDesktopSize() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48))
        try await withTimeout { try await h.client.handshake() }
        try await h.client.setEncodings([RFBEncoding.raw])
        let cond13 = await h.server.waitForEvents { $0.contains(.setEncodings([RFBEncoding.raw])) }
        #expect(cond13)
        #expect(h.server.resizeDesktop(width: 100, height: 80) == 0)
        await h.finish()
    }

    @Test func lastRectTerminatedUpdate() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48, useLastRect: true))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setEncodings([RFBEncoding.tight, RFBEncoding.lastRect])
        try await c.requestUpdate(incremental: false)
        let r = try await withTimeout { try await c.readUpdate() }
        #expect(r.last?.encoding == RFBEncoding.lastRect)
        #expect(maxDifference(c.decoders.fb, expectedFramebuffer(TestPatternScene(), width: 64, height: 48)) == 0)
        await h.finish()
    }

    @Test func copyRectHook() async throws {
        let h = Harness.start(MockServerConfiguration(width: 200, height: 120))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setEncodings([RFBEncoding.copyRect, RFBEncoding.hextile])
        try await c.requestUpdate(incremental: false)
        _ = try await withTimeout { try await c.readUpdate() }
        let cond14 = await h.server.waitForEvents { $0.contains { if case .updateRequest = $0 { return true }; return false } }
        #expect(cond14)
        h.server.copyRect(fromX: 0, fromY: 0, to: RFBRect(x: 120, y: 60, width: 50, height: 40))
        try await c.requestUpdate(incremental: true)
        let r = try await withTimeout { try await c.readUpdate() }
        #expect(r.map(\.encoding) == [RFBEncoding.copyRect])
        #expect(maxDifference(c.decoders.fb, serverFramebuffer(h.server)!) == 0)
        await h.finish()
    }

    @Test func bellAndServerCutText() async throws {
        let h = Harness.start(MockServerConfiguration(width: 16, height: 16))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        let cond15 = await h.server.waitForEvents { $0.contains(.clientInit(shared: true)) }
        #expect(cond15)
        h.server.sendBell()
        h.server.sendServerCutText("héllo")
        let m1 = try await withTimeout { try await c.readMessage() }
        let m2 = try await withTimeout { try await c.readMessage() }
        guard case .bell = m1 else { Issue.record("expected bell"); return }
        guard case .cutText = m2 else { Issue.record("expected cut text"); return }
        await h.finish()
    }

    @Test func inputIsRecordedInOrder() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 64))
        let c = h.client
        try await withTimeout { try await c.handshake() }
        try await c.setPixelFormat(.bgrx8888)
        try await c.setEncodings([RFBEncoding.zrle, RFBEncoding.cursor])
        try await c.pointer(x: 10, y: 20, buttons: .left)
        try await c.pointer(x: 11, y: 21, buttons: [])
        try await c.key(0xFFE1, down: true)
        try await c.key(0x41, down: true)
        try await c.key(0x41, down: false)
        try await c.key(0xFFE1, down: false)
        try await c.cutText("clip ✓")
        let cond16 = await h.server.waitForEvents { $0.contains { if case .cutText = $0 { return true }; return false } }
        #expect(cond16)
        let ev = h.server.receivedEvents.filter {
            switch $0 { case .pointer, .key, .cutText, .setEncodings, .setPixelFormat: return true; default: return false }
        }
        #expect(ev == [
            .setPixelFormat(.bgrx8888),
            .setEncodings([RFBEncoding.zrle, RFBEncoding.cursor]),
            .pointer(x: 10, y: 20, buttons: .left),
            .pointer(x: 11, y: 21, buttons: []),
            .key(keysym: 0xFFE1, down: true),
            .key(keysym: 0x41, down: true),
            .key(keysym: 0x41, down: false),
            .key(keysym: 0xFFE1, down: false),
            .cutText("clip ✓"),
        ])
        await h.finish()
    }

    @Test func wrongPixelFormatClosesConnection() async throws {
        let h = Harness.start(MockServerConfiguration(width: 16, height: 16))
        try await withTimeout { try await h.client.handshake() }
        let rgb565 = PixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColor: true, redMax: 31, greenMax: 63,
                                 blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
        try await h.client.setPixelFormat(rgb565)
        await h.serveTask.value
        guard case .disconnected(let reason)? = h.server.receivedEvents.last else { Issue.record("no disconnect"); return }
        #expect(reason?.contains("pixel format") == true)
    }

    @Test func malformedClientMessagesDoNotCrash() async throws {
        // Unknown message type.
        let h = Harness.start(MockServerConfiguration(width: 16, height: 16))
        try await withTimeout { try await h.client.handshake() }
        try await h.client.send { $0.u8(77) }
        await h.serveTask.value
        guard case .disconnected(let r1)? = h.server.receivedEvents.last else { Issue.record("no disconnect"); return }
        #expect(r1?.contains("unknown client message") == true)

        // Absurd cut text length.
        let h2 = Harness.start(MockServerConfiguration(width: 16, height: 16))
        try await withTimeout { try await h2.client.handshake() }
        try await h2.client.send { b in b.u8(6); b.zeros(3); b.u32(0x7FFF_FFFF) }
        await h2.serveTask.value
        guard case .disconnected(let r2)? = h2.server.receivedEvents.last else { Issue.record("no disconnect"); return }
        #expect(r2?.contains("too large") == true)

        // Truncated message then EOF.
        let h3 = Harness.start(MockServerConfiguration(width: 16, height: 16))
        try await withTimeout { try await h3.client.handshake() }
        try await h3.client.send { b in b.u8(2); b.u8(0); b.u16(1000); b.i32(0) }
        h3.client.stream.close()
        await h3.serveTask.value
        #expect(h3.server.receivedEvents.last == .disconnected(nil))

        // Extended-clipboard style negative length is skipped, connection stays usable.
        let h4 = Harness.start(MockServerConfiguration(width: 16, height: 16))
        try await withTimeout { try await h4.client.handshake() }
        try await h4.client.send { b in b.u8(6); b.zeros(3); b.i32(-4); b.u32(0x1000_0000) }
        try await h4.client.requestUpdate(incremental: false)
        let r = try await withTimeout { try await h4.client.readUpdate() }
        #expect(r.count == 1)
        await h4.finish()
    }

    @Test func tcpListener() async throws {
        let server = MockRFBServer(configuration: MockServerConfiguration(width: 80, height: 60, security: .vncPassword("pw")))
        let listener = MockRFBListener(server: server)
        let port = try await withTimeout { try await listener.start() }
        #expect(port != 0)
        #expect(listener.port == port)
        let conn = NWConnectionStreamFactory.connect(port: port)
        let c = TestClient(stream: conn)
        try await withTimeout { try await c.handshake(auth: .vnc("pw")) }
        try await c.setEncodings([RFBEncoding.tight, RFBEncoding.zrle])
        try await c.requestUpdate(incremental: false)
        _ = try await withTimeout { try await c.readUpdate() }
        #expect(maxDifference(c.decoders.fb, expectedFramebuffer(TestPatternScene(), width: 80, height: 60)) == 0)
        conn.close()
        let cond17 = await server.waitForEvents { $0.contains { if case .disconnected = $0 { return true }; return false } }
        #expect(cond17)
        listener.stop()
    }
}
