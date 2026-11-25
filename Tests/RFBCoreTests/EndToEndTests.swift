import Foundation
import Testing
@testable import RFBCore
import RFBMockServer

/// Real RFBClient + real RFBDecoders + real RFBSecurity handlers against MockRFBServer.
@Suite struct EncodingEndToEndTests {
    static let exactEncodings: [Int32] = [RFBEncoding.raw, RFBEncoding.hextile, RFBEncoding.zlib,
                                          RFBEncoding.zrle, RFBEncoding.tight]

    @Test(arguments: exactEncodings)
    func fullFramePixelExact(encoding: Int32) async throws {
        // Odd size so no encoding's tiles line up with the edges. JPEG off: Tight must be lossless here.
        let s = PipeSession.make(server: MockServerConfiguration(width: 333, height: 211),
                                 decoders: [encoding], jpegQuality: nil)
        let info = try await s.connectAndWaitForFirstFrame()
        #expect(info.width == 333 && info.height == 211)
        #expect(info.name == "Duo VNC Mock")
        let expected = try #require(serverSnapshot(s.server))
        let diff = compare(s.client.framebuffer, expected)
        #expect(diff.sizeMatches && diff.mismatched == 0, "\(encoding): \(diff)")
        let used = Set(s.server.sentUpdates.flatMap { $0.rects.map(\.encoding) }.filter { $0 >= 0 })
        #expect(used == [encoding])
        #expect((s.client.statistics.rectsByEncoding[encoding] ?? 0) > 0)
        await s.close()
    }

    @Test(arguments: exactEncodings)
    func incrementalUpdateAfterSceneChange(encoding: Int32) async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 200, height: 150),
                                 decoders: [encoding], jpegQuality: nil)
        _ = try await s.connectAndWaitForFirstFrame()
        let before = s.collector.updateCount()
        let changed = RFBRect(x: 37, y: 21, width: 71, height: 45)
        s.server.withScene { _, fb in
            try? fb.fill(changed, blue: 10, green: 200, red: 30)
            try? fb.fill(RFBRect(x: 40, y: 30, width: 5, height: 5), blue: 255, green: 0, red: 255)
            return [changed]
        }
        let ok = await s.collector.wait { evs in
            evs.contains { if case .framebufferUpdated(let r) = $0 { return r.contains(changed) } else { return false } }
        }
        #expect(ok)
        #expect(s.collector.updateCount() > before)
        let diff = compare(s.client.framebuffer, try #require(serverSnapshot(s.server)))
        #expect(diff.mismatched == 0, "\(encoding): \(diff)")
        await s.close()
    }

    @Test func tightJPEGWithinTolerance() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 320, height: 240),
                                 decoders: [RFBEncoding.tight], jpegQuality: 9)
        _ = try await s.connectAndWaitForFirstFrame()
        let encodings = s.server.receivedEvents.compactMap { if case .setEncodings(let e) = $0 { return e } else { return nil } }.last
        #expect(encodings?.contains(RFBEncoding.jpegQuality(9)) == true)
        let diff = compare(s.client.framebuffer, try #require(serverSnapshot(s.server)))
        #expect(diff.sizeMatches)
        #expect(diff.meanChannelDelta < 3, "\(diff)")
        #expect(diff.maxChannelDelta <= 64, "\(diff)")
        await s.close()
    }

    @Test func defaultWiringOn889ServerUsesTight() async throws {
        var cfg = MockServerConfiguration(width: 256, height: 160, versionLine: "RFB 003.889\n")
        cfg.useLastRect = true
        let s = PipeSession.make(server: cfg, jpegQuality: nil)
        let info = try await s.connectAndWaitForFirstFrame()
        #expect(info.serverVersion == "003.889")
        #expect(info.securityType == 1)
        // No macOS-account credential: the client answers Apple's 003.889 with the standard 003.008
        // (tailvnc / RoyalVNC behaviour); only type 33 logins use the 003.889 dialect.
        #expect(s.server.receivedEvents.contains(.clientVersion("RFB 003.008")))
        let encodings = s.server.receivedEvents.compactMap { if case .setEncodings(let e) = $0 { return e } else { return nil } }.last
        #expect(Array(encodings?.prefix(7) ?? []) == DefaultDecoders.preferenceOrder)
        #expect(encodings?.contains(RFBEncoding.lastRect) == true)
        #expect(s.server.receivedEvents.contains(.setPixelFormat(.bgrx8888)))
        let diff = compare(s.client.framebuffer, try #require(serverSnapshot(s.server)))
        #expect(diff.mismatched == 0, "\(diff)")
        #expect((s.client.statistics.rectsByEncoding[RFBEncoding.tight] ?? 0) > 0)
        #expect((s.client.statistics.rectsByEncoding[RFBEncoding.lastRect] ?? 0) > 0)
        await s.close()
    }

    @Test func copyRectHook() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 300, height: 200),
                                 decoders: [RFBEncoding.copyRect, RFBEncoding.zrle], jpegQuality: nil)
        _ = try await s.connectAndWaitForFirstFrame()
        s.server.copyRect(fromX: 10, fromY: 20, to: RFBRect(x: 150, y: 90, width: 100, height: 60))
        let ok = await s.collector.wait { _ in (s.client.statistics.rectsByEncoding[RFBEncoding.copyRect] ?? 0) > 0 }
        #expect(ok)
        _ = await s.collector.wait(timeout: 2) { _ in compare(s.client.framebuffer, serverSnapshot(s.server)!).mismatched == 0 }
        let diff = compare(s.client.framebuffer, try #require(serverSnapshot(s.server)))
        #expect(diff.mismatched == 0, "\(diff)")
        await s.close()
    }
}

@Suite struct SessionEndToEndTests {
    @Test func vncPasswordAccepted() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 64, height: 48, security: .vncPassword("s3cret!x")),
                                 credential: .vncPassword("s3cret!x"))
        let info = try await s.connectAndWaitForFirstFrame()
        #expect(info.securityType == 2)
        #expect(s.server.receivedEvents.contains(.authentication(succeeded: true)))
        await s.close()
    }

    @Test func vncPasswordAcceptedOnMacLikeServer() async throws {
        // macOS: 003.889 and [30, 33, 36, 2, 35]. A VNC-password credential must select type 2.
        let cfg = MockServerConfiguration(width: 64, height: 48, versionLine: "RFB 003.889\n",
                                          security: .vncPassword("pw"), advertisedSecurityTypes: [30, 33, 36, 2, 35])
        let s = PipeSession.make(server: cfg, credential: .vncPassword("pw"))
        let info = try await s.connectAndWaitForFirstFrame()
        #expect(info.securityType == 2)
        #expect(info.offeredSecurityTypes == [30, 33, 36, 2, 35])
        #expect(s.server.receivedEvents.contains(.securitySelected(2)))
        await s.close()
    }

    @Test(arguments: ["RFB 003.008\n", "RFB 003.889\n", "RFB 003.007\n", "RFB 003.003\n"])
    func vncPasswordRejected(version: String) async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 64, height: 48, versionLine: version,
                                                                 security: .vncPassword("right")),
                                 credential: .vncPassword("wrong"))
        await #expect(throws: RFBError.self) { _ = try await s.client.connect() }
        do { _ = try await s.client.connect() } catch {}
        let closed = await s.collector.wait { $0.contains { if case .closed(.some(.authenticationFailed)) = $0 { return true } else { return false } } }
        #expect(closed, "\(s.collector.events)")
        #expect(s.server.receivedEvents.contains(.authentication(succeeded: false)))
        await s.serveTask.value
    }

    @Test func macAccountCredentialAgainstVNCOnlyServerFailsCleanly() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 64, height: 48, security: .vncPassword("x")),
                                 credential: .macAccount(username: "nobody", password: "x"))
        await #expect(throws: RFBError.noUsableSecurityType(offered: [2])) { _ = try await s.client.connect() }
        await s.serveTask.value
    }

    @Test func inputArrivesInOrder() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 400, height: 300))
        _ = try await s.connectAndWaitForFirstFrame()
        s.server.clearLogs()
        let c = s.client
        c.sendPointer(x: 10, y: 20, buttons: [])
        c.sendPointer(x: 10, y: 20, buttons: .left)
        c.sendPointer(x: 10, y: 20, buttons: [])
        c.sendPointer(x: 5000, y: -3, buttons: .right)       // clamped to the framebuffer
        c.sendKey(keysym: 0x61, down: true)
        c.sendKey(keysym: 0x61, down: false)
        c.sendScroll(x: 50, y: 60, deltaX: 0, deltaY: 2, buttons: [])
        c.sendScroll(x: 50, y: 60, deltaX: -1, deltaY: 0, buttons: [])
        c.sendClipboard("héllo")
        let expected: [MockEvent] = [
            .pointer(x: 10, y: 20, buttons: []),
            .pointer(x: 10, y: 20, buttons: .left),
            .pointer(x: 10, y: 20, buttons: []),
            .pointer(x: 399, y: 0, buttons: .right),
            .key(keysym: 0x61, down: true),
            .key(keysym: 0x61, down: false),
            .pointer(x: 50, y: 60, buttons: .wheelDown), .pointer(x: 50, y: 60, buttons: []),
            .pointer(x: 50, y: 60, buttons: .wheelDown), .pointer(x: 50, y: 60, buttons: []),
            .pointer(x: 50, y: 60, buttons: .wheelLeft), .pointer(x: 50, y: 60, buttons: []),
            .cutText("héllo"),
        ]
        let ok = await s.server.waitForEvents { evs in
            evs.filter { if case .updateRequest = $0 { return false } else { return true } }.count >= expected.count
        }
        #expect(ok)
        let got = s.server.receivedEvents.filter { if case .updateRequest = $0 { return false } else { return true } }
        #expect(Array(got.prefix(expected.count)) == expected)
        await s.close()
    }

    @Test func desktopSizeChange() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 160, height: 120), decoders: [RFBEncoding.zrle])
        _ = try await s.connectAndWaitForFirstFrame()
        _ = s.server.resizeDesktop(width: 241, height: 97)
        let resized = await s.collector.wait { $0.contains(.desktopResized(width: 241, height: 97)) }
        #expect(resized)
        let ok = await s.collector.wait { _ in
            guard let snap = serverSnapshot(s.server) else { return false }
            return compare(s.client.framebuffer, snap).mismatched == 0 && s.client.framebuffer.width == 241
        }
        #expect(ok, "\(compare(s.client.framebuffer, serverSnapshot(s.server)!))")
        // The client asked for a full (non-incremental) update of the new size.
        #expect(s.server.receivedEvents.contains(.updateRequest(incremental: false, rect: RFBRect(x: 0, y: 0, width: 241, height: 97))))
        await s.close()
    }

    @Test func bellClipboardAndCursor() async throws {
        let s = PipeSession.make(server: MockServerConfiguration(width: 100, height: 80))
        _ = try await s.connectAndWaitForFirstFrame()
        s.server.sendBell()
        s.server.sendServerCutText("copied ü")
        let ok = await s.collector.wait { evs in evs.contains(.bell) && evs.contains(.clipboard("copied ü")) }
        #expect(ok)
        let cursor = s.collector.events.compactMap { if case .cursorChanged(let c) = $0 { return c } else { return nil } }.first
        let expected = MockCursors.arrow(scale: 1)
        #expect(cursor?.width == expected.width && cursor?.height == expected.height)
        #expect(cursor?.hotspotX == expected.hotspotX && cursor?.hotspotY == expected.hotspotY)
        // Opaque pixels match; transparent ones come back fully transparent.
        if let cursor {
            let a = [UInt8](cursor.bgra), b = [UInt8](expected.bgra)
            var bad = 0
            for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
                let opaque = b[i + 3] >= 128
                if opaque != (a[i + 3] == 255) { bad += 1; continue }
                if opaque && (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) { bad += 1 }
            }
            #expect(bad == 0)
        }
        await s.close()
    }

    @Test func disconnectByClientAndByServer() async throws {
        let s1 = PipeSession.make(server: MockServerConfiguration(width: 32, height: 32))
        _ = try await s1.connectAndWaitForFirstFrame()
        s1.client.disconnect()
        #expect(await s1.collector.wait { $0.last == .closed(nil) })
        await s1.serveTask.value
        #expect(s1.server.activeConnectionCount == 0)

        let s2 = PipeSession.make(server: MockServerConfiguration(width: 32, height: 32))
        _ = try await s2.connectAndWaitForFirstFrame()
        s2.server.disconnectAll()
        #expect(await s2.collector.wait { evs in
            if case .closed(.some) = evs.last { return true } else { return false }
        })
        await s2.serveTask.value
    }

    @Test func demoSceneClickRegisters() async throws {
        let s = PipeSession.make(server: .demo(width: 1280, height: 720))
        _ = try await s.connectAndWaitForFirstFrame()
        s.client.sendPointer(x: 640, y: 360, buttons: .left)
        s.client.sendPointer(x: 640, y: 360, buttons: [])
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            s.server.withScene { scene, _ in
                if let d = scene as? DemoDesktopScene { box.n = d.hits + d.misses }
                return []
            }
            if box.n > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(box.n == 1)
        // The redraw of the marker reaches the client.
        let ok = await s.collector.wait { _ in compare(s.client.framebuffer, serverSnapshot(s.server)!).mismatched == 0 }
        #expect(ok)
        await s.close()
    }
}

@Suite struct TCPEndToEndTests {
    @Test func demoDesktopOverRealTCP() async throws {
        let listener = MockRFBListener(server: MockRFBServer(configuration: .demo()))
        let port = try await listener.start()
        defer { listener.stop() }
        let cfg = RFBClientConfiguration.standard(host: "127.0.0.1", port: port, credential: .none)
        let client = RFBClient(configuration: cfg)
        let collector = EventCollector(client)
        let started = Date()
        let info = try await client.connect()
        #expect(info.width == 3840 && info.height == 2160)
        #expect(info.serverVersion == "003.889")
        let ok = await collector.wait(timeout: 30) { evs in
            evs.contains { if case .framebufferUpdated(let r) = $0 { return !r.isEmpty } else { return false } }
        }
        #expect(ok)
        let elapsed = Date().timeIntervalSince(started)
        print("4K demo frame over TCP: \(String(format: "%.2f", elapsed)) s, \(client.statistics.bytesReceived) bytes, \(client.statistics.rectsByEncoding)")
        let diff = compare(client.framebuffer, try #require(serverSnapshot(listener.server)))
        #expect(diff.sizeMatches)
        #expect(diff.meanChannelDelta < 1, "\(diff)")   // JPEG may be used for tiles with > 256 colours
        client.sendKey(keysym: 0x41, down: true)
        client.sendKey(keysym: 0x41, down: false)
        client.disconnect()
        #expect(await collector.wait { $0.last == .closed(nil) })
    }

    @Test func vncAuthOverRealTCPLossless() async throws {
        let server = MockRFBServer(configuration: MockServerConfiguration(width: 517, height: 293, security: .vncPassword("tcp-pw")))
        let listener = MockRFBListener(server: server)
        let port = try await listener.start()
        defer { listener.stop() }
        var cfg = RFBClientConfiguration.standard(host: "127.0.0.1", port: port, credential: .vncPassword("tcp-pw"))
        cfg.jpegQuality = nil
        let client = RFBClient(configuration: cfg)
        let collector = EventCollector(client)
        let info = try await client.connect()
        #expect(info.securityType == 2)
        #expect(await collector.wait { evs in evs.contains { if case .framebufferUpdated(let r) = $0 { return !r.isEmpty } else { return false } } })
        let diff = compare(client.framebuffer, try #require(serverSnapshot(server)))
        #expect(diff.mismatched == 0, "\(diff)")
        client.disconnect()
    }
}
