import Foundation
import Testing
@testable import RFBCore
import RFBMockServer

/// Collects a client's events on a background task so tests can wait for them.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RFBEvent] = []
    private var task: Task<Void, Never>?

    init(_ client: RFBClient) {
        task = Task { [weak self] in
            for await e in client.events {
                guard let self else { return }
                self.lock.withLock { self._events.append(e) }
            }
        }
    }

    var events: [RFBEvent] { lock.withLock { _events } }

    /// Polls until `predicate` holds on the events so far; returns whether it did before the timeout.
    func wait(timeout: TimeInterval = 10, _ predicate: ([RFBEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate(events)
    }

    func updateCount() -> Int {
        events.filter { if case .framebufferUpdated = $0 { return true } else { return false } }.count
    }

    var closedError: RFBError?? {
        for e in events { if case .closed(let err) = e { return .some(err) } }
        return nil
    }
}

/// One client wired to one in-process mock server over a PipeByteStream pair.
struct PipeSession {
    let server: MockRFBServer
    let client: RFBClient
    let collector: EventCollector
    let serveTask: Task<Void, Never>

    static func make(server config: MockServerConfiguration,
                     credential: RFBCredential = .none,
                     decoders: [Int32]? = nil,
                     jpegQuality: Int? = 6,
                     tweak: (inout RFBClientConfiguration) -> Void = { _ in }) -> PipeSession {
        let server = MockRFBServer(configuration: config)
        let (a, b) = PipeByteStream.makePair()
        let serveTask = Task { await server.serve(stream: a) }
        var cfg = RFBClientConfiguration.standard(host: "mock", credential: credential)
        if let decoders { cfg.decoderFactory = DefaultDecoders.factory(only: decoders) }
        cfg.jpegQuality = jpegQuality
        tweak(&cfg)
        let client = RFBClient(configuration: cfg, stream: b)
        return PipeSession(server: server, client: client, collector: EventCollector(client), serveTask: serveTask)
    }

    /// Connects and waits for the first FramebufferUpdate (the answer to the initial full request).
    func connectAndWaitForFirstFrame(timeout: TimeInterval = 20) async throws -> ServerInfo {
        let info = try await client.connect()
        let ok = await collector.wait(timeout: timeout) { evs in
            evs.contains { if case .framebufferUpdated(let r) = $0 { return !r.isEmpty } else { return false } }
        }
        #expect(ok, "no framebuffer update arrived")
        return info
    }

    func close() async {
        client.disconnect()
        await serveTask.value
    }
}

/// A copy of the server-side framebuffer of the (single) active connection.
func serverSnapshot(_ server: MockRFBServer) -> (pixels: [UInt8], width: Int, height: Int)? {
    final class Box: @unchecked Sendable { var v: (pixels: [UInt8], width: Int, height: Int)? }
    let box = Box()
    server.withScene { _, fb in
        fb.withPixels { p, w, h in box.v = (Array(p), w, h) }
        return []
    }
    return box.v
}

struct PixelDiff: CustomStringConvertible {
    var sizeMatches: Bool
    var mismatched = 0
    var maxChannelDelta = 0
    var meanChannelDelta = 0.0
    var firstMismatch: (Int, Int)?
    var description: String {
        "size=\(sizeMatches) mismatched=\(mismatched) maxDelta=\(maxChannelDelta) mean=\(meanChannelDelta) first=\(String(describing: firstMismatch))"
    }
}

/// Compares B, G, R of every pixel (the X/alpha byte is ignored).
func compare(_ fb: Framebuffer, _ expected: (pixels: [UInt8], width: Int, height: Int)) -> PixelDiff {
    fb.withPixels { p, w, h in
        var d = PixelDiff(sizeMatches: w == expected.width && h == expected.height)
        guard d.sizeMatches else { return d }
        var sum = 0
        for i in 0..<(w * h) {
            var bad = false
            for c in 0..<3 {
                let delta = abs(Int(p[i * 4 + c]) - Int(expected.pixels[i * 4 + c]))
                sum += delta
                if delta > 0 { bad = true; d.maxChannelDelta = max(d.maxChannelDelta, delta) }
            }
            if bad {
                d.mismatched += 1
                if d.firstMismatch == nil { d.firstMismatch = (i % w, i / w) }
            }
        }
        d.meanChannelDelta = w * h > 0 ? Double(sum) / Double(w * h * 3) : 0
        return d
    }
}
