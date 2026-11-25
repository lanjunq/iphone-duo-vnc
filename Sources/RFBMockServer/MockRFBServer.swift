import Foundation
import RFBBase

/// A fake RFB (VNC) server for end-to-end tests and the app's offline demo mode.
///
/// Each `serve(stream:)` call handles one client with its own scene, framebuffer and zlib streams.
/// Thread-safe: hooks and accessors may be called from any task while connections are served.
///
/// Update model: a non-incremental FramebufferUpdateRequest is answered with the whole requested area;
/// an incremental one is held until something in it is dirty (or a cursor / desktop-size change is due).
public final class MockRFBServer: @unchecked Sendable {
    public let configuration: MockServerConfiguration

    private let lock = NSLock()
    private var _events: [MockEvent] = []
    private var _sent: [MockSentUpdate] = []
    private var sessions: [ObjectIdentifier: MockSession] = [:]
    private var _connectionsServed = 0

    public init(configuration: MockServerConfiguration = MockServerConfiguration()) {
        self.configuration = configuration
    }

    /// Serves one client until it disconnects or violates the protocol, then closes the stream.
    /// Never throws; the end reason is recorded as `.disconnected`.
    public func serve(stream: ByteStream) async {
        let session = MockSession(server: self, stream: stream)
        let id = ObjectIdentifier(session)
        lock.withLock {
            sessions[id] = session
            _connectionsServed += 1
        }
        await session.run()
        lock.withLock { _ = sessions.removeValue(forKey: id) }
    }

    // MARK: Inspection

    /// Everything received from clients, oldest first (bounded by `eventLogLimit`).
    public var receivedEvents: [MockEvent] { lock.withLock { _events } }
    /// Every FramebufferUpdate sent, oldest first (bounded by `eventLogLimit`).
    public var sentUpdates: [MockSentUpdate] { lock.withLock { _sent } }
    public func clearLogs() { lock.withLock { _events.removeAll(); _sent.removeAll() } }
    /// Number of clients currently being served.
    public var activeConnectionCount: Int { lock.withLock { sessions.count } }
    /// Number of `serve(stream:)` calls so far.
    public var connectionsServed: Int { lock.withLock { _connectionsServed } }

    /// Polls until `predicate(receivedEvents)` is true or the timeout expires. Returns the final result.
    public func waitForEvents(timeout: TimeInterval = 5, _ predicate: @Sendable ([MockEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if predicate(receivedEvents) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Hooks (apply to every active connection)

    /// Changes the desktop size: clients that advertised DesktopSize (-223) receive a DesktopSize
    /// pseudo-rectangle with their next update, then the re-rendered scene. Returns the number of
    /// connections that will be resized (others keep their size).
    @discardableResult
    public func resizeDesktop(width: Int, height: Int) -> Int {
        let all = lock.withLock { Array(sessions.values) }
        return all.reduce(0) { $0 + ($1.requestResize(width: width, height: height) ? 1 : 0) }
    }

    /// Sends a Bell message to every client.
    public func sendBell() {
        var b = ByteBuilder(); b.u8(2)
        for s in lock.withLock({ Array(sessions.values) }) { s.enqueue(b.data) }
    }

    /// Sends ServerCutText (ISO 8859-1; other characters become "?") to every client.
    public func sendServerCutText(_ text: String) {
        let latin1 = text.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") }
        var b = ByteBuilder()
        b.u8(3); b.zeros(3); b.u32(UInt32(latin1.count)); b.bytes(latin1)
        for s in lock.withLock({ Array(sessions.values) }) { s.enqueue(b.data) }
    }

    /// Copies an area of the server framebuffer (like a scroll). Clients that advertised CopyRect get a
    /// CopyRect rectangle (when the source is clean on their side), others get the pixels.
    public func copyRect(fromX: Int, fromY: Int, to dest: RFBRect) {
        for s in lock.withLock({ Array(sessions.values) }) { s.copyRect(fromX: fromX, fromY: fromY, to: dest) }
    }

    /// Runs `body` with each active connection's scene and framebuffer (serialised with input handling);
    /// the returned rects are marked dirty and sent with the next update.
    public func withScene(_ body: (any MockScene, Framebuffer) -> [RFBRect]) {
        for s in lock.withLock({ Array(sessions.values) }) { s.mutateScene(body) }
    }

    /// Closes every active connection.
    public func disconnectAll() {
        for s in lock.withLock({ Array(sessions.values) }) { s.stream.close() }
    }

    // MARK: Internal

    func record(_ e: MockEvent) {
        let limit = configuration.eventLogLimit
        guard limit > 0 else { return }
        lock.withLock {
            _events.append(e)
            if _events.count > limit { _events.removeFirst(_events.count - limit) }
        }
    }

    func recordSent(_ u: MockSentUpdate) {
        let limit = configuration.eventLogLimit
        guard limit > 0 else { return }
        lock.withLock {
            _sent.append(u)
            if _sent.count > limit { _sent.removeFirst(_sent.count - limit) }
        }
    }
}

/// One client connection. The reader task (in `run`) parses client messages and drives the scene; a
/// sender task performs every write to the stream, so server messages never interleave.
final class MockSession: @unchecked Sendable {
    unowned let server: MockRFBServer
    let stream: ByteStream
    let config: MockServerConfiguration
    let reader: RFBReader
    let framebuffer: Framebuffer
    private let scene: any MockScene
    private let sceneLock = NSLock()

    // Shared state, guarded by `lock`.
    private let lock = NSLock()
    private var encodings: [Int32] = []
    private var fullRequest: RFBRect?
    private var incrementalRequest: RFBRect?
    private var dirty: [RFBRect] = []
    private var cursorPending = false
    private var cursorSent = false
    private var pendingResize: (width: Int, height: Int)?
    private var pendingCopies: [(srcX: Int, srcY: Int, dest: RFBRect)] = []
    private var outbox: [Data] = []
    private var handshakeDone = false
    private var closed = false

    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    // Encoders (sender task only).
    private var encoderCache: [Int32: any MockRectEncoder] = [:]

    init(server: MockRFBServer, stream: ByteStream) {
        self.server = server
        self.stream = stream
        self.config = server.configuration
        self.reader = RFBReader(stream: stream)
        let w = max(1, min(65535, config.width)), h = max(1, min(65535, config.height))
        self.framebuffer = Framebuffer(width: w, height: h)
        self.scene = config.sceneFactory(w, h)
        (wakeStream, wakeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Lifecycle

    func run() async {
        sceneLock.withLock { scene.render(into: framebuffer) }
        var reason: String? = nil
        var sender: Task<Void, Never>? = nil
        do {
            try await handshake()
            lock.withLock { handshakeDone = true }
            sender = Task { await self.senderLoop() }
            wake()
            try await readLoop()
        } catch RFBError.connectionClosed {
            reason = nil
        } catch {
            reason = "\(error)"
        }
        lock.withLock { closed = true }
        stream.close()
        wakeContinuation.finish()
        await sender?.value
        server.record(.disconnected(reason))
    }

    private func wake() { wakeContinuation.yield(()) }

    func enqueue(_ data: Data) {
        lock.withLock { outbox.append(data) }
        wake()
    }

    // MARK: Handshake

    static func parseVersion(_ bytes: [UInt8]) -> (major: Int, minor: Int)? {
        guard bytes.count == 12, bytes[0...3] == [0x52, 0x46, 0x42, 0x20], bytes[7] == 0x2E, bytes[11] == 0x0A else { return nil }
        func num(_ r: ArraySlice<UInt8>) -> Int? {
            var v = 0
            for b in r { guard b >= 0x30 && b <= 0x39 else { return nil }; v = v * 10 + Int(b - 0x30) }
            return v
        }
        guard let major = num(bytes[4...6]), let minor = num(bytes[8...10]) else { return nil }
        return (major, minor)
    }

    /// Effective protocol minor version for (major 3): 3, 7 or 8 (003.889 counts as 8).
    static func effectiveMinor(major: Int, minor: Int) -> Int? {
        guard major == 3 else { return major > 3 ? 8 : nil }
        if minor >= 8 { return 8 }
        if minor == 7 { return 7 }
        if minor >= 3 { return 3 }
        return nil
    }

    private func handshake() async throws {
        var line = Array(config.versionLine.utf8)
        if Self.parseVersion(line) == nil { line = Array("RFB 003.008\n".utf8) }
        let sv = Self.parseVersion(line)!
        let serverMinor = Self.effectiveMinor(major: sv.major, minor: sv.minor) ?? 8
        try await stream.write(Data(line))

        let clientLine = try await reader.bytes(12)
        guard let cv = Self.parseVersion(clientLine), let clientMinor = Self.effectiveMinor(major: cv.major, minor: cv.minor) else {
            throw RFBError.unsupportedProtocolVersion(String(decoding: clientLine, as: UTF8.self))
        }
        server.record(.clientVersion(String(decoding: clientLine.dropLast(), as: UTF8.self)))
        let version = min(serverMinor, clientMinor)

        let implemented = config.security.securityType
        let selected: UInt8
        if version == 3 {
            var b = ByteBuilder(); b.u32(UInt32(implemented))
            try await stream.write(b.data)
            selected = implemented
        } else {
            var types = config.advertisedSecurityTypes ?? [implemented]
            types = Array(types.prefix(255))
            if types.isEmpty {
                var b = ByteBuilder(); b.u8(0)
                let reason = Array("no security types configured".utf8)
                b.u32(UInt32(reason.count)); b.bytes(reason)
                try await stream.write(b.data)
                throw RFBError.protocolViolation("no security types configured")
            }
            var b = ByteBuilder(); b.u8(UInt8(types.count)); b.bytes(types)
            try await stream.write(b.data)
            selected = try await reader.u8()
            server.record(.securitySelected(selected))
            guard types.contains(selected), selected == implemented else {
                try await sendSecurityResult(ok: false, version: version, reason: "Security type \(selected) not supported")
                throw RFBError.noUsableSecurityType(offered: types)
            }
        }

        switch config.security {
        case .none:
            if version == 8 { try await sendSecurityResult(ok: true, version: version, reason: "") }
            server.record(.authentication(succeeded: true))
        case .vncPassword(let password):
            var challenge = [UInt8](repeating: 0, count: 16)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<16 { challenge[i] = UInt8.random(in: 0...255, using: &rng) }
            try await stream.write(Data(challenge))
            let response = try await reader.bytes(16)
            let expected = try MockVNCAuth.response(challenge: challenge, password: password)
            let ok = MockVNCAuth.constantTimeEqual(response, expected)
            server.record(.authentication(succeeded: ok))
            try await sendSecurityResult(ok: ok, version: version, reason: "Authentication failed")
            if !ok { throw RFBError.authenticationFailed("Authentication failed") }
        }

        let shared = try await reader.u8()
        server.record(.clientInit(shared: shared != 0))

        var si = ByteBuilder()
        si.u16(UInt16(framebuffer.width)); si.u16(UInt16(framebuffer.height))
        si.bytes(PixelFormat.bgrx8888.encoded())
        let name = Array(config.desktopName.utf8)
        si.u32(UInt32(name.count)); si.bytes(name)
        try await stream.write(si.data)
    }

    private func sendSecurityResult(ok: Bool, version: Int, reason: String) async throws {
        var b = ByteBuilder()
        b.u32(ok ? 0 : 1)
        if !ok && version == 8 {
            let r = Array(reason.utf8)
            b.u32(UInt32(r.count)); b.bytes(r)
        }
        try await stream.write(b.data)
    }

    // MARK: Client messages

    static let maxCutText = 1 << 20

    private func readLoop() async throws {
        while true {
            let type = try await reader.u8()
            switch type {
            case 0: // SetPixelFormat
                try await reader.skip(3)
                let pf = try PixelFormat(decoding: try await reader.bytes(16))
                server.record(.setPixelFormat(pf))
                guard pf == .bgrx8888 else {
                    throw RFBError.protocolViolation("unsupported pixel format \(pf); only bgrx8888 is accepted")
                }
            case 2: // SetEncodings
                try await reader.skip(1)
                let n = Int(try await reader.u16())
                var list = [Int32]()
                list.reserveCapacity(n)
                for _ in 0..<n { list.append(try await reader.i32()) }
                server.record(.setEncodings(list))
                lock.withLock {
                    encodings = list
                    if list.contains(RFBEncoding.cursor) && !cursorSent { cursorPending = true }
                }
                wake()
            case 3: // FramebufferUpdateRequest
                let incremental = try await reader.u8() != 0
                let x = Int(try await reader.u16()), y = Int(try await reader.u16())
                let w = Int(try await reader.u16()), h = Int(try await reader.u16())
                let r = RFBRect(x: x, y: y, width: w, height: h)
                server.record(.updateRequest(incremental: incremental, rect: r))
                lock.withLock {
                    if incremental {
                        incrementalRequest = incrementalRequest.map { $0.union(r) } ?? r
                    } else {
                        fullRequest = fullRequest.map { $0.union(r) } ?? r
                    }
                }
                wake()
            case 4: // KeyEvent
                let down = try await reader.u8() != 0
                try await reader.skip(2)
                let key = try await reader.u32()
                server.record(.key(keysym: key, down: down))
                let fb = framebuffer
                markDirty(sceneLock.withLock { scene.keyEvent(keysym: key, down: down, framebuffer: fb) })
            case 5: // PointerEvent
                let mask = RFBButtonMask(rawValue: try await reader.u8())
                let x = Int(try await reader.u16()), y = Int(try await reader.u16())
                server.record(.pointer(x: x, y: y, buttons: mask))
                let fb = framebuffer
                markDirty(sceneLock.withLock { scene.pointerEvent(x: x, y: y, buttons: mask, framebuffer: fb) })
            case 6: // ClientCutText
                try await reader.skip(3)
                let raw = try await reader.i32()
                // A negative length is the Extended Clipboard pseudo-encoding's format; we never advertise
                // it, but skip such a payload gracefully.
                let length = raw < 0 ? Int(raw.magnitude) : Int(raw)
                guard length <= Self.maxCutText else {
                    throw RFBError.protocolViolation("ClientCutText of \(length) bytes is too large")
                }
                let bytes = try await reader.bytes(length)
                if raw < 0 { continue }
                let text = String(bytes: bytes, encoding: .utf8)
                    ?? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
                server.record(.cutText(text))
                let fb = framebuffer
                markDirty(sceneLock.withLock { scene.cutText(text, framebuffer: fb) })
            default:
                throw RFBError.protocolViolation("unknown client message type \(type)")
            }
        }
    }

    // MARK: Dirty tracking and hooks

    private func markDirty(_ rects: [RFBRect]) {
        let bounds = RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
        let clipped = rects.map { $0.intersection(bounds) }.filter { !$0.isEmpty }
        if clipped.isEmpty { return }
        lock.withLock {
            for r in clipped where !dirty.contains(where: { $0.contains(r) }) {
                dirty.removeAll { r.contains($0) }
                dirty.append(r)
            }
            if dirty.count > 64 {
                dirty = [dirty.dropFirst().reduce(dirty[0]) { $0.union($1) }]
            }
        }
        wake()
    }

    func requestResize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= 65535, height <= 65535 else { return false }
        let ok: Bool = lock.withLock {
            guard !closed, encodings.contains(RFBEncoding.desktopSize) else { return false }
            pendingResize = (width, height)
            return true
        }
        if ok { wake() }
        return ok
    }

    func copyRect(fromX: Int, fromY: Int, to dest: RFBRect) {
        let fb = framebuffer
        let done: Bool = sceneLock.withLock {
            (try? fb.copy(fromX: fromX, y: fromY, to: dest)) != nil
        }
        guard done, !dest.isEmpty else { return }
        let src = RFBRect(x: fromX, y: fromY, width: dest.width, height: dest.height)
        lock.withLock {
            if encodings.contains(RFBEncoding.copyRect), config.supportedEncodings.contains(RFBEncoding.copyRect),
               pendingResize == nil, !dirty.contains(where: { $0.intersects(src) }) {
                pendingCopies.append((fromX, fromY, dest))
            } else {
                dirty.append(dest)
            }
        }
        wake()
    }

    func mutateScene(_ body: (any MockScene, Framebuffer) -> [RFBRect]) {
        let fb = framebuffer
        markDirty(sceneLock.withLock { body(scene, fb) })
    }

    // MARK: Sending

    private struct Plan {
        var resize: (width: Int, height: Int)?
        var copies: [(srcX: Int, srcY: Int, dest: RFBRect)] = []
        var rects: [RFBRect] = []
        var cursor = false
        var encodings: [Int32] = []
    }

    private func senderLoop() async {
        for await _ in wakeStream {
            if lock.withLock({ closed }) { break }
            do {
                try await flush()
            } catch {
                stream.close()
                break
            }
        }
    }

    private func makePlan() -> Plan? {
        lock.withLock { () -> Plan? in
            guard handshakeDone, fullRequest != nil || incrementalRequest != nil else { return nil }
            var plan = Plan()
            plan.encodings = encodings
            if let r = pendingResize {
                pendingResize = nil
                plan.resize = r
                pendingCopies = []
                dirty = []
                fullRequest = nil
                incrementalRequest = nil
                return plan
            }
            let bounds = RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
            let requested = [fullRequest, incrementalRequest].compactMap { $0 }.reduce(RFBRect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) }
                .intersection(bounds)
            if let f = fullRequest?.intersection(bounds), !f.isEmpty { plan.rects.append(f) }
            let fullCoversAll = plan.rects.first.map { $0.contains(bounds) } ?? false
            if !fullCoversAll {
                for d in dirty {
                    let i = d.intersection(requested)
                    if !i.isEmpty && !(plan.rects.first?.contains(i) ?? false) { plan.rects.append(i) }
                }
            }
            plan.copies = pendingCopies
            plan.cursor = cursorPending
            if fullRequest == nil && plan.rects.isEmpty && plan.copies.isEmpty && !plan.cursor {
                return nil   // hold the incremental request
            }
            dirty.removeAll { requested.contains($0) }
            pendingCopies = []
            if cursorPending { cursorPending = false; cursorSent = true }
            fullRequest = nil
            incrementalRequest = nil
            return plan
        }
    }

    private func encoder(for encoding: Int32, plan: Plan) -> any MockRectEncoder {
        let compression = plan.encodings.first { $0 >= -256 && $0 <= -247 }.map { Int($0 + 256) } ?? 6
        if let e = encoderCache[encoding] {
            if let t = e as? MockTightEncoder {
                t.jpegQuality = plan.encodings.first { $0 >= -32 && $0 <= -23 }.map { Int($0 + 32) }
            }
            return e
        }
        let e: any MockRectEncoder
        switch encoding {
        case RFBEncoding.hextile: e = MockHextileEncoder()
        case RFBEncoding.zlib: e = MockZlibEncoder(level: compression)
        case RFBEncoding.zrle: e = MockZRLEEncoder(level: compression)
        case RFBEncoding.tight:
            e = MockTightEncoder(compressionLevel: compression,
                                 jpegQuality: plan.encodings.first { $0 >= -32 && $0 <= -23 }.map { Int($0 + 32) })
        default: e = MockRawEncoder()
        }
        encoderCache[encoding] = e
        return e
    }

    static let realEncodings: Set<Int32> = [RFBEncoding.raw, RFBEncoding.hextile, RFBEncoding.zlib, RFBEncoding.tight, RFBEncoding.zrle]

    private func flush() async throws {
        let messages: [Data] = lock.withLock { let m = outbox; outbox = []; return m }
        for m in messages { try await stream.write(m) }
        guard let plan = makePlan() else { return }

        var rects = [MockEncodedRect]()
        if plan.cursor { rects.append(Self.encodeCursor(sceneLock.withLock { scene.cursor })) }
        if let r = plan.resize {
            let fb = framebuffer
            sceneLock.withLock {
                fb.resize(width: r.width, height: r.height)
                scene.render(into: fb)
            }
            rects.append(MockEncodedRect(rect: RFBRect(x: 0, y: 0, width: r.width, height: r.height),
                                         encoding: RFBEncoding.desktopSize, payload: Data()))
            lock.withLock { dirty = [RFBRect(x: 0, y: 0, width: r.width, height: r.height)] }
        } else {
            for c in plan.copies { rects.append(MockCopyRect.encode(dest: c.dest, srcX: c.srcX, srcY: c.srcY)) }
            let chosen = plan.encodings.first { Self.realEncodings.contains($0) && config.supportedEncodings.contains($0) } ?? RFBEncoding.raw
            let enc = encoder(for: chosen, plan: plan)
            for r in plan.rects { rects.append(contentsOf: try enc.encode(r, from: framebuffer)) }
        }
        let lastRect = config.useLastRect && plan.encodings.contains(RFBEncoding.lastRect)
        if !lastRect && rects.count > 65535 {
            throw RFBError.protocolViolation("update has too many rectangles")
        }
        var total = 4
        for r in rects { total += 12 + r.payload.count }
        var b = ByteBuilder(capacity: total + 12)
        b.u8(0); b.u8(0)
        b.u16(lastRect ? 0xFFFF : UInt16(rects.count))
        for r in rects { b.bytes(r.wireBytes) }
        if lastRect {
            b.zeros(8); b.i32(RFBEncoding.lastRect)
        }
        try await stream.write(b.data)
        server.recordSent(MockSentUpdate(rects: rects.map { MockSentRect(rect: $0.rect, encoding: $0.encoding, payloadBytes: $0.payload.count) }))
    }

    /// Cursor pseudo-encoding (-239): x,y = hotspot; payload = w*h pixels (B,G,R,0) then a 1-bit mask,
    /// rows padded to whole bytes, most significant bit first, 1 = opaque.
    static func encodeCursor(_ c: RFBCursor) -> MockEncodedRect {
        let w = max(0, c.width), h = max(0, c.height)
        guard c.bgra.count >= w * h * 4 else {
            return MockEncodedRect(rect: RFBRect(x: 0, y: 0, width: 0, height: 0), encoding: RFBEncoding.cursor, payload: Data())
        }
        let src = [UInt8](c.bgra)
        var pixels = [UInt8](); pixels.reserveCapacity(w * h * 4)
        let rowBytes = (w + 7) / 8
        var mask = [UInt8](repeating: 0, count: rowBytes * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                pixels.append(src[i]); pixels.append(src[i + 1]); pixels.append(src[i + 2]); pixels.append(0)
                if src[i + 3] >= 128 { mask[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8) }
            }
        }
        let hx = min(max(0, c.hotspotX), max(0, w - 1)), hy = min(max(0, c.hotspotY), max(0, h - 1))
        return MockEncodedRect(rect: RFBRect(x: hx, y: hy, width: w, height: h), encoding: RFBEncoding.cursor,
                               payload: Data(pixels + mask))
    }
}
