import Foundation
import RFBBase

/// An RFB (VNC) client session: handshake, receive loop, and input.
///
/// Concurrency model: a `final class` with internal serialization (not an actor), so the UI can call
/// the input methods synchronously from the main thread.
/// - `connect()` performs the handshake on the caller's task, then starts two background tasks:
///   a receive loop (the only user of the `RFBReader` and the decoders after the handshake) and a
///   writer that drains a FIFO of fully built messages.
/// - Every outgoing message after the handshake (input, update requests) is built completely and
///   appended to that FIFO under a lock, so messages never interleave, order is preserved, and the
///   `send*` methods return immediately without waiting for the network or the receive loop.
/// - `disconnect()` closes the transport (which fails a pending read at once) and finishes `events`
///   with exactly one `.closed(nil)`. Any failure finishes it with `.closed(error)`; whichever comes
///   first wins and `.closed` is always the last event.
/// - Input sent before `connect()` returns, or after the session closed, is dropped.
/// - `events` uses unbounded buffering: consume it for the whole session.
public final class RFBClient: @unchecked Sendable {
    public let configuration: RFBClientConfiguration
    /// The decoded remote screen (0x0 until ServerInit).
    public let framebuffer: Framebuffer
    /// Session events; ends after `.closed`.
    public let events: AsyncStream<RFBEvent>

    private let eventContinuation: AsyncStream<RFBEvent>.Continuation
    private let injectedStream: ByteStream?

    private enum Phase { case idle, connecting, connected, closed }

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var finished = false
    private var stream: CountingByteStream?
    private var outgoing: AsyncStream<Data>.Continuation?
    private var connectTask: Task<NWByteStream, Error>?
    private var stats = RFBStatistics()

    private let eventLock = NSLock()
    private var eventsFinished = false

    /// Upper bounds that protect against malformed / hostile input.
    enum Limits {
        static let maxDimension = 16384
        static let maxPixels = 64 * 1024 * 1024
        static let maxStringLength = 1 << 20          // reason strings, desktop name
        static let maxCutTextLength = 16 << 20
        static let maxCursorDimension = 1024
        static let maxColourMapEntries = 65536
        static let maxScrollSteps = 100
        static let reasonReadTimeoutNanos: UInt64 = 3_000_000_000
    }

    /// - Parameter stream: inject an already connected stream (tests, in-process demo server);
    ///   nil = open a TCP connection to `configuration.host:port` in `connect()`.
    public init(configuration: RFBClientConfiguration, stream: ByteStream? = nil) {
        self.configuration = configuration
        self.injectedStream = stream
        self.framebuffer = Framebuffer(width: 0, height: 0)
        var cont: AsyncStream<RFBEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.eventContinuation = cont
    }

    deinit {
        stream?.close()
        injectedStream?.close()
        outgoing?.finish()
        eventContinuation.finish()
    }

    // MARK: - Public API

    /// Connects, authenticates and performs the init phase. Returns after ServerInit, once the receive
    /// loop is running and SetPixelFormat / SetEncodings / the first full update request are queued.
    /// Throws `RFBError` (`.connectionClosed` if `disconnect()` or task cancellation interrupted it).
    /// May be called once per client.
    public func connect() async throws -> ServerInfo {
        try lock.withLock {
            switch phase {
            case .idle: break
            case .closed: throw RFBError.connectionClosed
            case .connecting, .connected: throw RFBError.protocolViolation("connect() called twice")
            }
            phase = .connecting
            stats.connectStartedAt = Date()
        }
        do {
            return try await withTaskCancellationHandler {
                try await performConnect()
            } onCancel: {
                self.disconnect()
            }
        } catch {
            let mapped = Self.map(error)
            let closedByUs = lock.withLock { finished }
            finish(error: mapped)
            throw closedByUs ? RFBError.connectionClosed : mapped
        }
    }

    /// Closes the session. Idempotent. Finishes `events` with `.closed(nil)` unless it already closed.
    public func disconnect() {
        finish(error: nil)
    }

    /// PointerEvent at remote pixel (x, y), clamped to the framebuffer, with the given buttons held.
    public func sendPointer(x: Int, y: Int, buttons: RFBButtonMask) {
        let (cx, cy) = clampToFramebuffer(x: x, y: y)
        enqueue(ClientMessages.pointerEvent(x: cx, y: cy, buttons: buttons))
    }

    /// KeyEvent with an X11 keysym.
    public func sendKey(keysym: UInt32, down: Bool) {
        enqueue(ClientMessages.keyEvent(keysym: keysym, down: down))
    }

    /// Scroll wheel clicks at (x, y). `deltaY` < 0 scrolls up (button 4), > 0 down (button 5);
    /// `deltaX` < 0 left (button 6), > 0 right (button 7). Each click is a press (with `buttons` held)
    /// followed by a release; at most 100 clicks per axis per call. All events go out as one unit.
    public func sendScroll(x: Int, y: Int, deltaX: Int, deltaY: Int, buttons: RFBButtonMask) {
        let (cx, cy) = clampToFramebuffer(x: x, y: y)
        var data = Data()
        func clicks(_ n: Int, _ wheel: RFBButtonMask) {
            for _ in 0..<min(abs(n), Limits.maxScrollSteps) {
                data.append(ClientMessages.pointerEvent(x: cx, y: cy, buttons: buttons.union(wheel)))
                data.append(ClientMessages.pointerEvent(x: cx, y: cy, buttons: buttons))
            }
        }
        if deltaY != 0 { clicks(deltaY, deltaY < 0 ? .wheelUp : .wheelDown) }
        if deltaX != 0 { clicks(deltaX, deltaX < 0 ? .wheelLeft : .wheelRight) }
        if !data.isEmpty { enqueue(data) }
    }

    /// ClientCutText. Text is sent as Latin-1; other characters become "?".
    public func sendClipboard(_ text: String) {
        enqueue(ClientMessages.clientCutText(text))
    }

    /// Non-incremental FramebufferUpdateRequest for the whole framebuffer.
    public func requestFullUpdate() {
        let (w, h) = framebuffer.size
        enqueue(ClientMessages.updateRequest(incremental: false, x: 0, y: 0, width: w, height: h))
    }

    /// Snapshot of the counters.
    public var statistics: RFBStatistics {
        lock.withLock {
            var s = stats
            if let stream {
                s.bytesReceived = stream.received
                s.bytesSent = stream.sent
            }
            return s
        }
    }

    // MARK: - Connect / handshake

    private func performConnect() async throws -> ServerInfo {
        let raw: ByteStream
        if let injectedStream {
            raw = injectedStream
        } else {
            let cfg = configuration
            let task = Task { try await NWByteStream.connect(host: cfg.host, port: cfg.port, timeout: cfg.connectTimeout) }
            let alreadyClosed = lock.withLock { () -> Bool in
                if phase == .closed { return true }
                connectTask = task
                return false
            }
            if alreadyClosed { task.cancel() }
            do {
                raw = try await task.value
            } catch is CancellationError {
                throw RFBError.connectionClosed
            }
        }
        let counted = CountingByteStream(raw)
        let attached = lock.withLock { () -> Bool in
            connectTask = nil
            if phase == .closed { return false }
            stream = counted
            return true
        }
        guard attached else {
            raw.close()
            throw RFBError.connectionClosed
        }

        let reader = RFBReader(stream: counted)
        let info = try await handshake(reader: reader, stream: counted)

        let decoders = configuration.decoderFactory()
        let encodings = Self.encodingList(decoders: decoders, configuration: configuration)
        let (outStream, outCont) = AsyncStream<Data>.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let started = lock.withLock { () -> Bool in
            guard phase == .connecting else { return false }
            phase = .connected
            outgoing = outCont
            stats.serverInitAt = Date()
            // Queued under the lock so they precede any input message.
            outCont.yield(ClientMessages.setPixelFormat(.bgrx8888))
            outCont.yield(ClientMessages.setEncodings(encodings))
            outCont.yield(ClientMessages.updateRequest(incremental: false, x: 0, y: 0, width: info.width, height: info.height))
            return true
        }
        guard started else {
            outCont.finish()
            throw RFBError.connectionClosed
        }
        let receiver = ReceiveLoop(client: self, reader: reader, decoders: decoders)
        // Detached so decoding never runs on the caller's actor (e.g. the main actor in the app).
        Task.detached(priority: .userInitiated) { [self] in await self.runWriter(outStream, stream: counted) }
        Task.detached(priority: .userInitiated) { await receiver.run() }
        return info
    }

    /// Builds the SetEncodings list: decoders in order, then the pseudo-encodings we handle.
    static func encodingList(decoders: [any RectDecoder], configuration: RFBClientConfiguration) -> [Int32] {
        var list: [Int32] = []
        for d in decoders where !list.contains(d.encoding) { list.append(d.encoding) }
        if configuration.requestRemoteCursor { list.append(RFBEncoding.cursor) }
        list.append(RFBEncoding.desktopSize)
        list.append(RFBEncoding.lastRect)
        if list.contains(RFBEncoding.tight) {
            if let q = configuration.jpegQuality { list.append(RFBEncoding.jpegQuality(q)) }
            if let c = configuration.compressionLevel { list.append(RFBEncoding.compressionLevel(c)) }
        }
        return list
    }

    private enum ProtocolLevel { case v33, v37, v38 }

    private func handshake(reader: RFBReader, stream: ByteStream) async throws -> ServerInfo {
        // 1. ProtocolVersion
        let versionBytes = try await reader.bytes(12)
        guard let (major, minor) = Self.parseVersion(versionBytes) else {
            let printable = String(decoding: versionBytes.map { (0x20...0x7e).contains($0) ? $0 : 0x3f }, as: UTF8.self)
            throw RFBError.unsupportedProtocolVersion(printable)
        }
        let serverVersionLine = String(decoding: versionBytes.prefix(11), as: UTF8.self)  // "RFB 003.889"
        let serverVersion = String(serverVersionLine.dropFirst(4))                        // "003.889"
        let level: ProtocolLevel
        let reply: String
        if major == 3 && minor == 889, case .macAccount = configuration.credential {
            // Apple Screen Sharing. Its macOS-account login (type 33) needs the Apple version in reply;
            // tailvnc answers 003.889 only in this case and 003.008 otherwise (as does RoyalVNC, which
            // always answers 003.008), so VNC-password / None sessions use the standard 3.8 dialect.
            level = .v38; reply = "RFB 003.889\n"
        } else if major > 3 || (major == 3 && minor >= 8) {
            level = .v38; reply = "RFB 003.008\n"
        } else if major == 3 && minor == 7 {
            level = .v37; reply = "RFB 003.007\n"
        } else if major == 3 && minor >= 3 {
            level = .v33; reply = "RFB 003.003\n"   // RFC 6143 §7.1.1: other 3.x versions → 3.3
        } else {
            throw RFBError.unsupportedProtocolVersion(serverVersionLine)
        }
        try await stream.write(Data(reply.utf8))

        // 2. Security
        let credential = configuration.credential
        let context = SecurityContext(serverVersion: serverVersionLine, hostKeyVerifier: configuration.hostKeyVerifier)
        var offered: [UInt8]
        let handler: any SecurityHandler
        if level == .v33 {
            let type = try await reader.u32()
            if type == 0 {
                let reason = try await readString(reader)
                throw RFBError.connectionFailed("server refused the connection: \(reason)")
            }
            offered = type <= 255 ? [UInt8(type)] : []
            guard type <= 255, let h = configuration.securityHandlers.first(where: {
                $0.securityType == UInt8(type) && $0.canHandle(credential)
            }) else {
                throw RFBError.noUsableSecurityType(offered: offered)
            }
            handler = h
        } else {
            let count = Int(try await reader.u8())
            if count == 0 {
                let reason = try await readString(reader)
                throw RFBError.connectionFailed("server refused the connection: \(reason)")
            }
            offered = try await reader.bytes(count)
            guard let h = configuration.securityHandlers.first(where: {
                offered.contains($0.securityType) && $0.canHandle(credential)
            }) else {
                throw RFBError.noUsableSecurityType(offered: offered)
            }
            handler = h
        }
        // 3.3: the server chose the type, no selection byte. 3.7+: the selection byte goes out together
        // with the handler's first message when the handler needs that (macOS type 33).
        let outcome: SecurityOutcome
        if level == .v33 {
            outcome = try await handler.authenticate(reader: reader, stream: stream, credential: credential, context: context)
        } else {
            outcome = try await handler.selectAndAuthenticate(reader: reader, stream: stream, credential: credential, context: context)
        }
        // RFC 6143 §7.2.1/§7.1.3: with security type None, 3.3 and 3.7 send no SecurityResult.
        let skipResult = handler.securityType == 1 && level != .v38
        if outcome == .readSecurityResult && !skipResult {
            let result = try await reader.u32()
            if result != 0 {
                var reason: String? = nil
                if level == .v38 {
                    reason = await readFailureReason(reader, stream: stream)
                }
                throw RFBError.authenticationFailed(reason)
            }
        }

        // 3. ClientInit / ServerInit
        try await stream.write(Data([configuration.shared ? 1 : 0]))
        let width = Int(try await reader.u16())
        let height = Int(try await reader.u16())
        let pf = try PixelFormat(decoding: try await reader.bytes(16))
        let name = try await readString(reader)
        try Self.validateSize(width: width, height: height)
        framebuffer.resize(width: width, height: height)
        return ServerInfo(width: width, height: height, nativePixelFormat: pf, name: name,
                          serverVersion: serverVersion, securityType: handler.securityType,
                          offeredSecurityTypes: offered)
    }

    /// Parses "RFB xxx.yyy\n" strictly.
    static func parseVersion(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count == 12, b[0] == 0x52, b[1] == 0x46, b[2] == 0x42, b[3] == 0x20,
              b[7] == 0x2e, b[11] == 0x0a else { return nil }
        func num(_ s: ArraySlice<UInt8>) -> Int? {
            var v = 0
            for c in s {
                guard c >= 0x30 && c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard let major = num(b[4..<7]), let minor = num(b[8..<11]) else { return nil }
        return (major, minor)
    }

    static func validateSize(width: Int, height: Int) throws {
        guard width >= 0, height >= 0, width <= Limits.maxDimension, height <= Limits.maxDimension,
              width * height <= Limits.maxPixels else {
            throw RFBError.protocolViolation("unsupported framebuffer size \(width)x\(height)")
        }
    }

    /// u32 length + bytes, UTF-8 (lossy), bounded.
    func readString(_ reader: RFBReader) async throws -> String {
        let n = Int(try await reader.u32())
        guard n <= Limits.maxStringLength else {
            throw RFBError.protocolViolation("string length \(n) too large")
        }
        return try await reader.string(n)
    }

    /// The 3.8 failure reason after a non-zero SecurityResult. Some servers send none and keep the
    /// socket open, so give up after a few seconds (closing the stream; the session is failing anyway).
    private func readFailureReason(_ reader: RFBReader, stream: ByteStream) async -> String? {
        let timer = Task {
            try await Task.sleep(nanoseconds: Limits.reasonReadTimeoutNanos)
            stream.close()
        }
        defer { timer.cancel() }
        let reason = try? await readString(reader)
        if let reason, reason.isEmpty { return nil }
        return reason
    }

    // MARK: - Output

    private func enqueue(_ data: Data) {
        lock.withLock {
            guard phase == .connected, let outgoing else { return }
            outgoing.yield(data)
        }
    }

    private func runWriter(_ messages: AsyncStream<Data>, stream: ByteStream) async {
        for await message in messages {
            do {
                try await stream.write(message)
            } catch {
                finish(error: Self.map(error))
                return
            }
        }
    }

    private func clampToFramebuffer(x: Int, y: Int) -> (Int, Int) {
        let (w, h) = framebuffer.size
        return (min(max(0, x), max(0, w - 1)), min(max(0, y), max(0, h - 1)))
    }

    // MARK: - Receive loop support (called from ReceiveLoop)

    func emit(_ event: RFBEvent) {
        eventLock.withLock {
            guard !eventsFinished else { return }
            eventContinuation.yield(event)
        }
    }

    func requestUpdate(incremental: Bool) {
        let (w, h) = framebuffer.size
        enqueue(ClientMessages.updateRequest(incremental: incremental, x: 0, y: 0, width: w, height: h))
    }

    func recordRect(encoding: Int32) {
        lock.withLock {
            stats.rects += 1
            stats.rectsByEncoding[encoding, default: 0] += 1
        }
    }

    func recordUpdate() {
        lock.withLock {
            stats.updates += 1
            if stats.firstUpdateAt == nil { stats.firstUpdateAt = Date() }
        }
    }

    /// Ends the session exactly once: closes the transport (failing any pending read), stops the
    /// writer, and finishes `events` with `.closed(error)`.
    func finish(error: RFBError?) {
        let state: (CountingByteStream?, AsyncStream<Data>.Continuation?, Task<NWByteStream, Error>?)? = lock.withLock {
            if finished { return nil }
            finished = true
            phase = .closed
            let r = (stream, outgoing, connectTask)
            outgoing = nil
            connectTask = nil
            return r
        }
        guard let (s, out, ct) = state else { return }
        out?.finish()
        ct?.cancel()
        s?.close()
        injectedStream?.close()
        eventLock.withLock {
            guard !eventsFinished else { return }
            eventsFinished = true
            eventContinuation.yield(.closed(error))
            eventContinuation.finish()
        }
    }

    static func map(_ error: Error) -> RFBError {
        if let e = error as? RFBError { return e }
        if error is CancellationError { return .connectionClosed }
        return .connectionFailed(String(describing: error))
    }
}

/// Owns the reader and the decoders after the handshake; runs on one task only.
private final class ReceiveLoop: @unchecked Sendable {
    private let client: RFBClient
    private let reader: RFBReader
    private var decoders: [Int32: any RectDecoder] = [:]

    init(client: RFBClient, reader: RFBReader, decoders: [any RectDecoder]) {
        self.client = client
        self.reader = reader
        for d in decoders where self.decoders[d.encoding] == nil { self.decoders[d.encoding] = d }
    }

    func run() async {
        do {
            while true {
                try await readMessage()
            }
        } catch {
            client.finish(error: RFBClient.map(error))
        }
    }

    private func readMessage() async throws {
        let type = try await reader.u8()
        switch type {
        case 0:
            try await framebufferUpdate()
        case 1:
            // SetColourMapEntries: padding, first colour, count, count * (r, g, b) u16. Not used with
            // our true-colour format, but must be consumed.
            try await reader.skip(1)
            _ = try await reader.u16()
            let count = Int(try await reader.u16())
            try await reader.skip(count * 6)
        case 2:
            client.emit(.bell)
        case 3:
            try await reader.skip(3)
            let raw = try await reader.u32()
            // A negative length would be the Extended Clipboard pseudo-encoding, which we never advertise.
            let length = Int(Int32(bitPattern: raw).magnitude)
            guard length <= RFBClient.Limits.maxCutTextLength else {
                throw RFBError.protocolViolation("ServerCutText length \(length) too large")
            }
            let bytes = try await reader.bytes(length)
            if Int32(bitPattern: raw) >= 0 {
                let text = String(bytes.map { Character(Unicode.Scalar($0)) })
                client.emit(.clipboard(text))
            }
        default:
            throw RFBError.protocolViolation("unknown server message type \(type)")
        }
    }

    private func framebufferUpdate() async throws {
        try await reader.skip(1)
        let count = Int(try await reader.u16())
        var rects: [RFBRect] = []
        var needFullUpdate = false
        rectLoop: for _ in 0..<count {
            let x = Int(try await reader.u16())
            let y = Int(try await reader.u16())
            let w = Int(try await reader.u16())
            let h = Int(try await reader.u16())
            let encoding = try await reader.i32()
            let rect = RFBRect(x: x, y: y, width: w, height: h)
            client.recordRect(encoding: encoding)
            switch encoding {
            case RFBEncoding.lastRect:
                break rectLoop
            case RFBEncoding.cursor:
                let cursor = try await readCursor(rect)
                client.emit(.cursorChanged(cursor))
            case RFBEncoding.desktopSize:
                try RFBClient.validateSize(width: w, height: h)
                client.framebuffer.resize(width: w, height: h)
                client.emit(.desktopResized(width: w, height: h))
                needFullUpdate = true
            default:
                guard let decoder = decoders[encoding] else {
                    throw RFBError.unsupportedEncoding(encoding)
                }
                let (fw, fh) = client.framebuffer.size
                guard rect.maxX <= fw, rect.maxY <= fh else {
                    throw RFBError.protocolViolation("rect \(x),\(y) \(w)x\(h) outside framebuffer \(fw)x\(fh)")
                }
                try await decoder.decode(rect: rect, reader: reader, framebuffer: client.framebuffer)
                rects.append(rect)
            }
        }
        client.recordUpdate()
        client.emit(.framebufferUpdated(rects))
        client.requestUpdate(incremental: !needFullUpdate)
    }

    /// Cursor pseudo-encoding: w*h pixels in our pixel format (B,G,R,X) then a 1-bpp mask,
    /// rows padded to whole bytes, most significant bit first. Hotspot = rect x/y.
    private func readCursor(_ rect: RFBRect) async throws -> RFBCursor {
        let w = rect.width, h = rect.height
        guard w <= RFBClient.Limits.maxCursorDimension, h <= RFBClient.Limits.maxCursorDimension else {
            throw RFBError.protocolViolation("cursor \(w)x\(h) too large")
        }
        let pixels = try await reader.bytes(w * h * 4)
        let maskRow = (w + 7) / 8
        let mask = try await reader.bytes(maskRow * h)
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let visible = mask[row * maskRow + col / 8] & (0x80 >> UInt8(col % 8)) != 0
                if visible {
                    bgra[i] = pixels[i]
                    bgra[i + 1] = pixels[i + 1]
                    bgra[i + 2] = pixels[i + 2]
                    bgra[i + 3] = 255
                }
            }
        }
        return RFBCursor(width: w, height: h,
                         hotspotX: w > 0 ? min(rect.x, w - 1) : 0,
                         hotspotY: h > 0 ? min(rect.y, h - 1) : 0,
                         bgra: Data(bgra))
    }
}
