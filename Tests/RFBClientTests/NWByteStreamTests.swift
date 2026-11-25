import Foundation
import Network
import Testing
@testable import RFBClient
import RFBBase

/// Minimal TCP server on 127.0.0.1 for transport tests. Mode: echo, or send a greeting then close.
final class LocalTCPServer: @unchecked Sendable {
    enum Mode { case echo, greetAndClose(Data), silent }
    let listener: NWListener
    let queue = DispatchQueue(label: "test.tcpserver")
    private let lock = NSLock()
    private var conns: [NWConnection] = []

    init(mode: Mode) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.withLock { self.conns.append(conn) }
            conn.start(queue: self.queue)
            switch mode {
            case .echo: self.echo(conn)
            case .greetAndClose(let d):
                conn.send(content: d, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            case .silent: break
            }
        }
    }

    private func echo(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
            if complete || error != nil { conn.cancel(); return }
            self.echo(conn)
        }
    }

    /// Starts and returns the bound port.
    func start() async throws -> UInt16 {
        let gate = OnceFlag()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if gate.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e):
                    if gate.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { conns.forEach { $0.cancel() } }
    }
}

@Suite struct NWByteStreamTests {
    @Test func echoRoundTripOverLoopback() async throws {
        let server = try LocalTCPServer(mode: .echo)
        let port = try await server.start()
        defer { server.stop() }
        let s = try await NWByteStream.connect(host: "127.0.0.1", port: port, timeout: 5)
        let payload = Data((0..<100_000).map { UInt8($0 & 0xff) })
        try await s.write(payload)
        let reader = RFBReader(stream: s)
        let back = try await reader.data(payload.count)
        #expect(back == payload)
        s.close()
        await #expect(throws: RFBError.connectionClosed) { _ = try await s.read(maxLength: 10) }
        await #expect(throws: RFBError.connectionClosed) { try await s.write(Data([1])) }
    }

    @Test func closeWakesPendingRead() async throws {
        let server = try LocalTCPServer(mode: .silent)
        let port = try await server.start()
        defer { server.stop() }
        let s = try await NWByteStream.connect(host: "127.0.0.1", port: port, timeout: 5)
        let readTask = Task { try await s.read(maxLength: 100) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        s.close()
        await #expect(throws: RFBError.connectionClosed) { _ = try await readTask.value }
        #expect(Date().timeIntervalSince(start) < 1)
        s.close()   // idempotent
    }

    @Test func peerCloseIsEOFAfterData() async throws {
        let server = try LocalTCPServer(mode: .greetAndClose(Data("RFB 003.008\n".utf8)))
        let port = try await server.start()
        defer { server.stop() }
        let s = try await NWByteStream.connect(host: "127.0.0.1", port: port, timeout: 5)
        let reader = RFBReader(stream: s)
        #expect(try await reader.string(12) == "RFB 003.008\n")
        await #expect(throws: RFBError.connectionClosed) { _ = try await reader.u8() }
        s.close()
    }

    @Test func refusedPortFailsQuickly() async throws {
        // Bind a listener to get a free port, then stop it so nothing listens there.
        let server = try LocalTCPServer(mode: .silent)
        let port = try await server.start()
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        do {
            _ = try await NWByteStream.connect(host: "127.0.0.1", port: port, timeout: 3)
            Issue.record("connect unexpectedly succeeded")
        } catch let e as RFBError {
            switch e {
            case .connectionFailed, .timeout: break
            default: Issue.record("unexpected \(e)")
            }
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func invalidInputs() async throws {
        await #expect(throws: RFBError.connectionFailed("empty host")) {
            _ = try await NWByteStream.connect(host: "  ", port: 5900)
        }
        await #expect(throws: RFBError.connectionFailed("invalid port 0")) {
            _ = try await NWByteStream.connect(host: "127.0.0.1", port: 0)
        }
    }

    @Test func clientOverRealTCPWithGreetingServer() async throws {
        // The server greets with 3.8 and closes; the client must report EOF, not hang.
        let server = try LocalTCPServer(mode: .greetAndClose(Data("RFB 003.008\n".utf8)))
        let port = try await server.start()
        defer { server.stop() }
        let client = RFBClient(configuration: RFBClientConfiguration(
            host: "127.0.0.1", port: port, credential: .none,
            securityHandlers: [TestNoneHandler()], decoderFactory: { [TestRawDecoder()] }, connectTimeout: 5))
        let collector = EventCollector(client.events)
        // The client's version reply can hit the already-closed socket, in which case the kernel
        // answers with a reset instead of a clean EOF. Both mean "the server went away".
        func isGone(_ e: RFBError?) -> Bool {
            switch e {
            case .connectionClosed?: return true
            case .connectionFailed(let m)?: return m.contains("reset")
            default: return false
            }
        }
        var thrown: RFBError?
        do { _ = try await client.connect() } catch { thrown = error as? RFBError }
        #expect(isGone(thrown), "connect() threw \(String(describing: thrown))")
        #expect(await collector.waitForEnd())
        #expect(collector.events.count == 1)
        if case .closed(let e)? = collector.events.first { #expect(isGone(e)) } else { Issue.record("no .closed event") }
    }

    @Test func disconnectWhileTCPConnecting() async throws {
        // 192.0.2.1 (TEST-NET-1) is never routable, so the connect stays pending until cancelled.
        let client = RFBClient(configuration: RFBClientConfiguration(
            host: "192.0.2.1", port: 5900, credential: .none,
            securityHandlers: [TestNoneHandler()], decoderFactory: { [] }, connectTimeout: 20))
        let collector = EventCollector(client.events)
        let t = Task { try await client.connect() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        client.disconnect()
        do {
            _ = try await t.value
            Issue.record("unexpected success")
        } catch let e as RFBError {
            // connectionClosed normally; connectionFailed if the OS already rejected the route.
            switch e {
            case .connectionClosed, .connectionFailed: break
            default: Issue.record("unexpected \(e)")
            }
        }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(await collector.waitForEnd())
        #expect(closedEvents(collector.events).count == 1)
    }
}
