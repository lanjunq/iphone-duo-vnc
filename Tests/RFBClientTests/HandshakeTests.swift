import Foundation
import Testing
@testable import RFBClient
import RFBBase

@Suite struct HandshakeTests {
    @Test func handshake38NoneAndServerInit() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let serverTask = Task { try await server.handshake38None(width: 640, height: 480, name: "Example’s Mac mini") }
        let info = try await client.connect()
        let (spf, _, fbur) = try await serverTask.value
        #expect(info.width == 640 && info.height == 480)
        #expect(info.name == "Example’s Mac mini")
        #expect(info.serverVersion == "003.008")
        #expect(info.securityType == 1)
        #expect(info.offeredSecurityTypes == [1])
        #expect(info.nativePixelFormat == .bgrx8888)
        #expect(client.framebuffer.width == 640 && client.framebuffer.height == 480)
        // SetPixelFormat
        let wantSPF: [UInt8] = [0, 0, 0, 0] + Array(PixelFormat.bgrx8888.encoded())
        #expect(spf == wantSPF)
        #expect(spf[4...7] == [32, 24, 0, 1])
        // full non-incremental request
        let wantFBUR: [UInt8] = [3, 0, 0, 0, 0, 0, 0x02, 0x80, 0x01, 0xe0]
        #expect(fbur == wantFBUR)
        client.disconnect()
    }

    /// A VNC-password session against Apple's 003.889 answers 003.008 (like tailvnc and RoyalVNC);
    /// the handler still sees the server's own version line.
    @Test func handshake889WithVNCPasswordReplies38AndPassesVersionToHandler() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let rec = ContextRecorder()
        let config = makeConfig(credential: .vncPassword("k"),
                                handlers: [TestChallengeHandler(securityType: 33, recorder: rec),
                                           TestChallengeHandler(securityType: 2, recorder: rec)])
        let client = RFBClient(configuration: config, stream: c)
        let serverTask = Task { () -> ([UInt8], [UInt8]) in
            try await server.send("RFB 003.889\n")
            let v = try await server.read(12)
            // The real macOS server offers [30, 33, 36, 2, 35].
            try await server.send([5, 30, 33, 36, 2, 35])
            let sel = try await server.read(1)
            try await server.send([9, 8, 7, 6])
            let answer = try await server.read(4)
            let expectedAnswer: [UInt8] = [9, 8, 7, 6].map { $0 ^ UInt8(0x6b) }
            #expect(answer == expectedAnswer)
            try await server.send([0, 0, 0, 0])
            #expect(try await server.read(1) == [1])
            try await server.sendServerInit(width: 3840, height: 2160, name: "mini")
            _ = try await server.readInitMessages()
            return (v, sel)
        }
        let info = try await client.connect()
        let (v, sel) = try await serverTask.value
        #expect(String(decoding: v, as: UTF8.self) == "RFB 003.008\n")
        #expect(sel == [33])                       // first injected handler that is offered
        #expect(rec.versions == ["RFB 003.889"])
        #expect(info.serverVersion == "003.889")
        #expect(info.securityType == 33)
        #expect(info.offeredSecurityTypes == [30, 33, 36, 2, 35])
        #expect(info.width == 3840 && info.height == 2160)
        client.disconnect()
    }

    @Test(arguments: [
        ("RFB 003.008\n", "RFB 003.008\n"),
        ("RFB 003.889\n", "RFB 003.008\n"),   // credential .none: standard dialect
        ("RFB 004.001\n", "RFB 003.008\n"),
        ("RFB 003.010\n", "RFB 003.008\n"),
        ("RFB 003.007\n", "RFB 003.007\n"),
        ("RFB 003.005\n", "RFB 003.003\n"),
        ("RFB 003.003\n", "RFB 003.003\n"),
    ])
    func versionReplies(server serverLine: String, expected: String) async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let collector = EventCollector(client.events)
        let connectTask = Task { try await client.connect() }
        try await server.send(serverLine)
        let reply = try await server.readString(12)
        #expect(reply == expected)
        s.close()
        await #expect(throws: RFBError.connectionClosed) { try await connectTask.value }
        #expect(await collector.waitForEnd())
        #expect(collector.events == [.closed(.connectionClosed)])
    }

    /// macOS-account login (type 33) needs the Apple dialect: answer 003.889 in kind (tailvnc RFBClient.swift).
    @Test func macAccountAgainst889RepliesInKind() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(credential: .macAccount(username: "u", password: "p")),
                               stream: c)
        let connectTask = Task { try await client.connect() }
        try await server.send("RFB 003.889\n")
        #expect(try await server.readString(12) == "RFB 003.889\n")
        s.close()
        await #expect(throws: RFBError.connectionClosed) { try await connectTask.value }
    }

    @Test(arguments: ["RFB 002.002\n", "HTTP/1.1 400", "RFB 003.00x\n", "RFB 003.008\r"])
    func badVersionIsRejected(line: String) async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        try await server.send(Array(line.utf8.prefix(12)))
        do {
            _ = try await client.connect()
            Issue.record("expected failure")
        } catch let e as RFBError {
            guard case .unsupportedProtocolVersion = e else { Issue.record("got \(e)"); return }
        }
    }

    @Test func zeroSecurityTypesWithReason() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let collector = EventCollector(client.events)
        let serverTask = Task {
            try await server.send("RFB 003.008\n")
            _ = try await server.read(12)
            var b = ByteBuilder()
            b.u8(0); b.u32(17); b.ascii("Too many failures")
            try await server.send(b)
        }
        let expected = RFBError.connectionFailed("server refused the connection: Too many failures")
        await #expect(throws: expected) { try await client.connect() }
        _ = try? await serverTask.value
        #expect(await collector.waitForEnd())
        #expect(collector.events == [.closed(expected)])
    }

    @Test func securityResultFailureWithReason38() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(credential: .vncPassword("pw"),
                                                         handlers: [TestChallengeHandler()]), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.008\n")
            _ = try await server.read(12)
            try await server.send([2, 1, 2])
            #expect(try await server.read(1) == [2])
            try await server.send([1, 2, 3, 4])
            _ = try await server.read(4)
            var b = ByteBuilder()
            b.u32(1); b.u32(18); b.ascii("Authentication bad")
            try await server.send(b)
        }
        await #expect(throws: RFBError.authenticationFailed("Authentication bad")) { try await client.connect() }
        _ = try? await serverTask.value
    }

    @Test func securityResultFailureWithoutReasonDoesNotHang() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(credential: .vncPassword("pw"),
                                                         handlers: [TestChallengeHandler()]), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.008\n")
            _ = try await server.read(12)
            try await server.send([1, 2])
            _ = try await server.read(1)
            try await server.send([1, 2, 3, 4])
            _ = try await server.read(4)
            try await server.send([0, 0, 0, 1])   // failed, no reason, socket stays open
        }
        let start = Date()
        await #expect(throws: RFBError.authenticationFailed(nil)) { try await client.connect() }
        _ = try? await serverTask.value
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func noUsableSecurityType() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        // VNC handler cannot handle .none; None is not offered.
        let client = RFBClient(configuration: makeConfig(credential: .none,
                                                         handlers: [TestChallengeHandler(), TestNoneHandler()]), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.889\n")
            _ = try await server.read(12)
            try await server.send([5, 30, 33, 36, 2, 35])
        }
        await #expect(throws: RFBError.noUsableSecurityType(offered: [30, 33, 36, 2, 35])) { try await client.connect() }
        _ = try? await serverTask.value
    }

    @Test func rfb33ServerChosenTypeWithResult() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(credential: .vncPassword("a"),
                                                         handlers: [TestChallengeHandler()],
                                                         shared: false), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.003\n")
            #expect(try await server.readString(12) == "RFB 003.003\n")
            try await server.send([0, 0, 0, 2])                 // u32 security type, no selection byte
            try await server.send([1, 1, 1, 1])
            let resp = try await server.read(4)
            let want: [UInt8] = [UInt8](repeating: 1 ^ 0x61, count: 4)
            #expect(resp == want)
            try await server.send([0, 0, 0, 0])
            #expect(try await server.read(1) == [0])            // shared = false
            try await server.sendServerInit(width: 8, height: 8, name: "old")
            _ = try await server.readInitMessages()
        }
        let info = try await client.connect()
        try await serverTask.value
        #expect(info.securityType == 2 && info.offeredSecurityTypes == [2] && info.serverVersion == "003.003")
        client.disconnect()
    }

    @Test func rfb33NoneHasNoSecurityResult() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.003\n")
            _ = try await server.read(12)
            try await server.send([0, 0, 0, 1])
            #expect(try await server.read(1) == [1])            // ClientInit directly
            try await server.sendServerInit(width: 4, height: 4, name: "")
            _ = try await server.readInitMessages()
        }
        let info = try await client.connect()
        try await serverTask.value
        #expect(info.name == "" && info.width == 4)
        client.disconnect()
    }

    @Test func rfb33FailureWithReason() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.003\n")
            _ = try await server.read(12)
            var b = ByteBuilder(); b.u32(0); b.u32(2); b.ascii("no")
            try await server.send(b)
        }
        await #expect(throws: RFBError.connectionFailed("server refused the connection: no")) { try await client.connect() }
        _ = try? await serverTask.value
    }

    @Test func rfb37NoneHasNoSecurityResult() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.007\n")
            #expect(try await server.readString(12) == "RFB 003.007\n")
            try await server.send([2, 2, 1])
            #expect(try await server.read(1) == [1])
            #expect(try await server.read(1) == [1])            // ClientInit, no SecurityResult in between
            try await server.sendServerInit(width: 4, height: 4, name: "x")
            _ = try await server.readInitMessages()
        }
        _ = try await client.connect()
        try await serverTask.value
        client.disconnect()
    }

    @Test func rfb37FailureHasNoReason() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(credential: .vncPassword("p"),
                                                         handlers: [TestChallengeHandler()]), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.007\n")
            _ = try await server.read(12)
            try await server.send([1, 2])
            _ = try await server.read(1)
            try await server.send([0, 0, 0, 0])
            _ = try await server.read(4)
            try await server.send([0, 0, 0, 1])
        }
        let start = Date()
        await #expect(throws: RFBError.authenticationFailed(nil)) { try await client.connect() }
        _ = try? await serverTask.value
        #expect(Date().timeIntervalSince(start) < 1)   // did not wait for a reason string
    }

    @Test func handlerCompletedOutcomeSkipsResult() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(credential: .vncPassword("p"),
                                                         handlers: [TestChallengeHandler(securityType: 33, outcome: .completed)]), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.889\n")
            _ = try await server.read(12)
            try await server.send([1, 33])
            _ = try await server.read(1)
            try await server.send([0, 0, 0, 0])
            _ = try await server.read(4)
            #expect(try await server.read(1) == [1])   // ClientInit right away
            try await server.sendServerInit(width: 2, height: 2, name: "m")
            _ = try await server.readInitMessages()
        }
        _ = try await client.connect()
        try await serverTask.value
        client.disconnect()
    }

    @Test func absurdServerInitSizeIsRejected() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.008\n")
            _ = try await server.read(12)
            try await server.send([1, 1]); _ = try await server.read(1)
            try await server.send([0, 0, 0, 0]); _ = try await server.read(1)
            try await server.sendServerInit(width: 65535, height: 65535, name: "huge")
        }
        do {
            _ = try await client.connect()
        _ = try? await serverTask.value
            Issue.record("expected failure")
        } catch let e as RFBError {
            guard case .protocolViolation = e else { Issue.record("got \(e)"); return }
        }
    }

    @Test func hugeNameLengthIsRejected() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let serverTask = Task {
            try await server.send("RFB 003.008\n")
            _ = try await server.read(12)
            try await server.send([1, 1]); _ = try await server.read(1)
            try await server.send([0, 0, 0, 0]); _ = try await server.read(1)
            var b = ByteBuilder()
            b.u16(10); b.u16(10); b.bytes(PixelFormat.bgrx8888.encoded()); b.u32(0xffff_ffff)
            try await server.send(b)
        }
        do {
            _ = try await client.connect()
        _ = try? await serverTask.value
            Issue.record("expected failure")
        } catch let e as RFBError {
            guard case .protocolViolation = e else { Issue.record("got \(e)"); return }
        }
    }

    @Test func encodingsListWithTight() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let config = makeConfig(decoders: { [DummyDecoder(RFBEncoding.copyRect), DummyDecoder(RFBEncoding.tight),
                                             DummyDecoder(RFBEncoding.zrle), TestRawDecoder()] })
        let client = RFBClient(configuration: config, stream: c)
        let serverTask = Task { try await server.handshake38None() }
        _ = try await client.connect()
        let (_, encs, _) = try await serverTask.value
        #expect(encs == [1, 7, 16, 0, -239, -223, -224, -26, -250])
        client.disconnect()
    }

    @Test func encodingsListWithoutTightOrCursor() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let config = makeConfig(decoders: { [DummyDecoder(RFBEncoding.zrle), TestRawDecoder()] }, requestRemoteCursor: false)
        let client = RFBClient(configuration: config, stream: c)
        let serverTask = Task { try await server.handshake38None() }
        _ = try await client.connect()
        let (_, encs, _) = try await serverTask.value
        #expect(encs == [16, 0, -223, -224])
        client.disconnect()
    }

    @Test func disconnectDuringHandshake() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let collector = EventCollector(client.events)
        let connectTask = Task { try await client.connect() }
        try await server.send("RFB 003.008\n")
        _ = try await server.read(12)          // client is now waiting for the security list
        client.disconnect()
        await #expect(throws: RFBError.connectionClosed) { try await connectTask.value }
        #expect(await collector.waitForEnd())
        #expect(collector.events == [.closed(nil)])
        // connect() after close fails immediately
        await #expect(throws: RFBError.connectionClosed) { try await client.connect() }
    }

    @Test func cancellingConnectTaskClosesSession() async throws {
        let (c, s) = PipeByteStream.makePair()
        let server = FakeServer(s)
        let client = RFBClient(configuration: makeConfig(), stream: c)
        let collector = EventCollector(client.events)
        let connectTask = Task { try await client.connect() }
        try await server.send("RFB 003.008\n")
        _ = try await server.read(12)
        connectTask.cancel()
        await #expect(throws: RFBError.connectionClosed) { try await connectTask.value }
        #expect(await collector.waitForEnd())
        #expect(collector.events == [.closed(nil)])
    }
}
