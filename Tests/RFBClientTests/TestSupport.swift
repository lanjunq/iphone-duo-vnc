import Foundation
import Testing
@testable import RFBClient
import RFBBase

/// Trivial Raw decoder used only in tests.
final class TestRawDecoder: RectDecoder {
    let encoding: Int32 = RFBEncoding.raw
    func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        let bytes = try await reader.bytes(rect.width * rect.height * 4)
        try framebuffer.writeBGRX(rect, bytes)
    }
}

/// A decoder that only claims an encoding number (for SetEncodings tests); never decodes.
final class DummyDecoder: RectDecoder {
    let encoding: Int32
    init(_ e: Int32) { encoding = e }
    func decode(rect: RFBRect, reader: RFBReader, framebuffer: Framebuffer) async throws {
        throw RFBError.decodeFailed("dummy")
    }
}

/// Security type None as a handler (always asks for SecurityResult; the client must skip it on 3.3/3.7).
struct TestNoneHandler: SecurityHandler {
    let securityType: UInt8 = 1
    func canHandle(_ credential: RFBCredential) -> Bool { credential == .none }
    func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                      context: SecurityContext) async throws -> SecurityOutcome { .readSecurityResult }
}

/// Records the context it saw.
final class ContextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _versions: [String] = []
    func add(_ v: String) { lock.withLock { _versions.append(v) } }
    var versions: [String] { lock.withLock { _versions } }
}

/// A toy challenge-response scheme: server sends 4 bytes, client answers them XOR'ed with the
/// password's first byte. Exercises handler I/O through the shared reader/stream.
struct TestChallengeHandler: SecurityHandler {
    var securityType: UInt8 = 2
    var recorder: ContextRecorder? = nil
    var outcome: SecurityOutcome = .readSecurityResult
    func canHandle(_ credential: RFBCredential) -> Bool {
        if case .vncPassword = credential { return true }
        return false
    }
    func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                      context: SecurityContext) async throws -> SecurityOutcome {
        recorder?.add(context.serverVersion)
        guard case .vncPassword(let p) = credential else { throw RFBError.authenticationFailed(nil) }
        let key = p.utf8.first ?? 0
        let challenge = try await reader.bytes(4)
        try await stream.write(Data(challenge.map { $0 ^ key }))
        return outcome
    }
}

/// The server end of a pipe, driven by the test script.
final class FakeServer: @unchecked Sendable {
    let stream: PipeByteStream
    let reader: RFBReader

    init(_ stream: PipeByteStream) {
        self.stream = stream
        self.reader = RFBReader(stream: stream, chunkSize: 4096)
    }

    func send(_ bytes: [UInt8]) async throws { try await stream.write(Data(bytes)) }
    func send(_ b: ByteBuilder) async throws { try await stream.write(b.data) }
    func send(_ s: String) async throws { try await stream.write(Data(s.utf8)) }
    func read(_ n: Int) async throws -> [UInt8] { try await reader.bytes(n) }
    func readString(_ n: Int) async throws -> String { try await reader.string(n) }

    /// Standard ServerInit.
    func sendServerInit(width: Int, height: Int, name: String) async throws {
        var b = ByteBuilder()
        b.u16(UInt16(width)); b.u16(UInt16(height))
        b.bytes(PixelFormat.bgrx8888.encoded())
        let n = Data(name.utf8)
        b.u32(UInt32(n.count)); b.bytes(n)
        try await send(b)
    }

    /// Reads SetPixelFormat (20) + SetEncodings + first FramebufferUpdateRequest (10).
    /// Returns (pixel format bytes, encodings, update request bytes).
    func readInitMessages() async throws -> ([UInt8], [Int32], [UInt8]) {
        let spf = try await read(20)
        let head = try await read(4)
        #expect(head[0] == 2)
        let n = Int(head[2]) << 8 | Int(head[3])
        var encs: [Int32] = []
        for _ in 0..<n { encs.append(try await reader.i32()) }
        let fbur = try await read(10)
        return (spf, encs, fbur)
    }

    /// Full 3.8 handshake with security None. Returns the init messages.
    @discardableResult
    func handshake38None(width: Int = 64, height: Int = 32, name: String = "Test") async throws -> ([UInt8], [Int32], [UInt8]) {
        try await send("RFB 003.008\n")
        let v = try await readString(12)
        #expect(v == "RFB 003.008\n")
        try await send([1, 1])
        let sel = try await read(1)
        #expect(sel == [1])
        try await send([0, 0, 0, 0])
        let ci = try await read(1)
        #expect(ci == [1])
        try await sendServerInit(width: width, height: height, name: name)
        return try await readInitMessages()
    }
}

func makeConfig(credential: RFBCredential = .none,
                handlers: [any SecurityHandler] = [TestNoneHandler()],
                decoders: @escaping RectDecoderFactory = { [TestRawDecoder()] },
                requestRemoteCursor: Bool = true,
                shared: Bool = true) -> RFBClientConfiguration {
    RFBClientConfiguration(host: "test", port: 5900, credential: credential, shared: shared,
                           securityHandlers: handlers, decoderFactory: decoders,
                           requestRemoteCursor: requestRemoteCursor)
}

/// Collects events until `.closed` (or a timeout) in the background.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RFBEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<RFBEvent>) {
        task = Task {
            for await e in stream { self.lock.withLock { self._events.append(e) } }
        }
    }

    var events: [RFBEvent] { lock.withLock { _events } }

    /// Waits until the predicate holds for the collected events (polling), up to `seconds`.
    @discardableResult
    func waitFor(seconds: Double = 5, _ pred: ([RFBEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if pred(events) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return pred(events)
    }

    /// Waits for the stream to finish.
    func waitForEnd(seconds: Double = 5) async -> Bool {
        guard let task else { return true }
        let done = LockedBox(false)
        let waiter = Task { await task.value; done.value = true }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done.value { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        waiter.cancel()
        return done.value
    }
}

func closedEvents(_ events: [RFBEvent]) -> [RFBEvent] {
    events.filter { if case .closed = $0 { return true } else { return false } }
}

