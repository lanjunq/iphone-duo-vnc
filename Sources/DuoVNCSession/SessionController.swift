import Foundation
import CoreGraphics
import RFBCore
import RFBMockServer
import DuoVNCKit

/// Receives session callbacks on the main actor.
@MainActor
public protocol SessionControllerDelegate: AnyObject {
    func session(_ session: SessionController, didChangeState state: SessionState)
    /// After a FramebufferUpdate was decoded into `framebuffer` (which changes object on reconnect).
    func session(_ session: SessionController, didUpdate framebuffer: Framebuffer, rects: [RFBRect])
    /// The remote screen size, on connect and on DesktopSize.
    func session(_ session: SessionController, didResizeToWidth width: Int, height: Int)
    func session(_ session: SessionController, didChangeCursor cursor: RFBCursor)
    func sessionDidRingBell(_ session: SessionController)
    func session(_ session: SessionController, didReceiveClipboard text: String)
    func session(_ session: SessionController, didChangeModifiers latch: ModifierLatch)
    /// First connection to a host that presents a key (type 33): show the fingerprint and ask.
    func session(_ session: SessionController, confirmNewHostKey fingerprint: String) async -> Bool
    /// The user trusted a new key; persist `host` (its `knownHostKeySHA256` is set).
    func session(_ session: SessionController, didPinHostKeyFor host: SavedHost)
    /// Input delivery started (true) or is being held (false): the Mac ignores input for a moment
    /// after connecting, so early input waits in a queue. Optional.
    func session(_ session: SessionController, didChangeInputReady ready: Bool)
}

public extension SessionControllerDelegate {
    func session(_ session: SessionController, didChangeInputReady ready: Bool) {}
}

/// One remote-desktop session: connection lifecycle, automatic reconnect, host-key trust, and input.
///
/// Runs on the main actor; the RFB client does its I/O on its own tasks. Every connection attempt has
/// a generation number, and callbacks from an older attempt are ignored, so suspend/resume/retry can
/// never mix two connections. Secrets passed to `typeSecret` are only turned into key events; they
/// are never logged, stored, or sent as clipboard text.
@MainActor
public final class SessionController {
    public let endpoint: SessionEndpoint
    /// The saved host (remote endpoints), updated when a host key gets pinned.
    public private(set) var host: SavedHost?
    public weak var delegate: SessionControllerDelegate?

    public private(set) var state: SessionState = .idle {
        didSet {
            if state != oldValue { delegate?.session(self, didChangeState: state) }
        }
    }
    public private(set) var serverInfo: ServerInfo?
    public var shiftStrategy: ShiftStrategy = .keysymOnly
    public private(set) var modifiers = ModifierLatch() {
        didSet {
            if modifiers != oldValue { delegate?.session(self, didChangeModifiers: modifiers) }
        }
    }
    public private(set) var reconnectPolicy: ReconnectPolicy
    /// The live client (nil between connections).
    public private(set) var client: RFBClient?
    /// Statistics of the live client.
    public var statistics: RFBStatistics? { client?.statistics }
    /// Last clipboard text received from the Mac.
    public private(set) var remoteClipboard: String?

    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var hostKeyEvent: HostKeyEvent?
    private var inProcessServer: MockRFBServer?
    private var sawFirstUpdate = false
    private var warmupElapsed = false
    private var warmupTask: Task<Void, Never>?

    /// How long after ServerInit input is held back. macOS Screen Sharing silently drops clicks and
    /// keys sent during roughly the first 2 seconds of a session (measured on macOS 27.0.1), so the
    /// default for a remote Mac is 2.5 s; the in-process demo server needs none.
    public var inputWarmup: TimeInterval
    /// Orders, spaces and (until the warm-up is over and a frame arrived) holds all input.
    public private(set) lazy var pacer: InputPacer = InputPacer { [weak self] input in
        self?.deliver(input)
    }
    /// True once input is actually being delivered to the server.
    public var isInputReady: Bool { pacer.isOpen }

    public init(endpoint: SessionEndpoint, reconnectPolicy: ReconnectPolicy = ReconnectPolicy()) {
        self.endpoint = endpoint
        self.reconnectPolicy = reconnectPolicy
        if case .remote(let host, _) = endpoint {
            self.host = host
            self.inputWarmup = 2.5
        } else {
            self.inputWarmup = 0
        }
    }

    deinit {
        connectTask?.cancel()
        retryTask?.cancel()
        client?.disconnect()
    }

    // MARK: - Lifecycle

    /// Starts the first connection. Does nothing unless idle.
    public func start() {
        guard case .idle = state else { return }
        connect()
    }

    /// User-initiated retry from any state except closed: resets the backoff and the host-key event.
    public func retryNow() {
        if case .closed = state { return }
        reconnectPolicy.reset()
        hostKeyEvent = nil
        connect()
    }

    /// App went to the background: drop the connection on purpose (the last frame stays on screen).
    public func suspend() {
        switch state {
        case .connecting, .connected, .waitingToReconnect:
            invalidate()
            state = .suspended
        default:
            break
        }
    }

    /// App returned to the foreground: reconnect if suspended or waiting/failed for a transient reason.
    public func resume() {
        switch state {
        case .suspended, .waitingToReconnect:
            reconnectPolicy.reset()
            connect()
        case .failed(let f) where f.kind == .transient:
            reconnectPolicy.reset()
            connect()
        default:
            break
        }
    }

    /// The network path became usable again: retry at once instead of waiting for the backoff.
    public func networkBecameAvailable() {
        switch state {
        case .waitingToReconnect:
            connect()
        case .failed(let f) where f.kind == .transient:
            reconnectPolicy.reset()
            connect()
        default:
            break
        }
    }

    /// Ends the session for good.
    public func close() {
        invalidate()
        modifiers.reset()
        state = .closed
    }

    /// Cancels timers and the current connection; stale callbacks are ignored afterwards.
    private func invalidate() {
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        connectTask?.cancel()
        connectTask = nil
        client?.disconnect()
        client = nil
        closeInputGate()
    }

    /// Stops input delivery and drops whatever is still queued, so input meant for one connection
    /// (a password, a click) is never replayed into the next one.
    private func closeInputGate() {
        warmupTask?.cancel()
        warmupTask = nil
        warmupElapsed = false
        let wasOpen = pacer.isOpen
        pacer.reset()
        if wasOpen { delegate?.session(self, didChangeInputReady: false) }
    }

    private func openInputGateIfReady(generation gen: Int) {
        guard gen == generation, state.isConnected, sawFirstUpdate, warmupElapsed, !pacer.isOpen else { return }
        pacer.isOpen = true
        delegate?.session(self, didChangeInputReady: true)
    }

    private func deliver(_ input: PacedInput) {
        guard let client, state.isConnected else { return }
        switch input {
        case .key(let keysym, let down):
            client.sendKey(keysym: keysym, down: down)
        case .pointer(let x, let y, let buttons):
            client.sendPointer(x: x, y: y, buttons: RFBButtonMask(rawValue: buttons))
        case .scroll(let x, let y, let dx, let dy, let buttons):
            client.sendScroll(x: x, y: y, deltaX: dx, deltaY: dy, buttons: RFBButtonMask(rawValue: buttons))
        }
    }

    private func connect() {
        invalidate()
        let gen = generation
        sawFirstUpdate = false
        hostKeyEvent = nil
        state = .connecting(attempt: reconnectPolicy.attempts)

        let newClient: RFBClient
        switch endpoint {
        case .remote(_, let credential):
            let h = host ?? SavedHost(displayName: "", host: "")
            let cfg = RFBClientConfiguration.standard(host: h.host, port: h.port, credential: credential,
                                                      hostKeyVerifier: makeVerifier(generation: gen))
            newClient = RFBClient(configuration: cfg)
        case .inProcess(let mockConfiguration, let credential):
            let server: MockRFBServer
            if let existing = inProcessServer {
                server = existing
            } else {
                server = MockRFBServer(configuration: mockConfiguration)
                inProcessServer = server
            }
            let (serverEnd, clientEnd) = PipeByteStream.makePair()
            Task.detached {
                await server.serve(stream: serverEnd)
            }
            newClient = RFBClient(configuration: .standard(host: "demo", credential: credential), stream: clientEnd)
        }
        client = newClient

        connectTask = Task { [weak self] in
            let info: ServerInfo
            do {
                info = try await newClient.connect()
            } catch {
                self?.connectionEnded(RFBClient.describe(error), generation: gen)
                return
            }
            guard let accepted = self?.didConnect(info, generation: gen), accepted else {
                newClient.disconnect()
                return
            }
            for await event in newClient.events {
                guard let me = self else {
                    newClient.disconnect()
                    return
                }
                me.handle(event, from: newClient, generation: gen)
            }
        }
    }

    private func didConnect(_ info: ServerInfo, generation gen: Int) -> Bool {
        guard gen == generation else { return false }
        serverInfo = info
        state = .connected(info)
        delegate?.session(self, didResizeToWidth: info.width, height: info.height)
        warmupTask?.cancel()
        let warmup = max(0, inputWarmup)
        if warmup == 0 {
            warmupElapsed = true
        } else {
            warmupElapsed = false
            warmupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(warmup * 1_000_000_000))
                if Task.isCancelled { return }
                guard let me = self, gen == me.generation else { return }
                me.warmupElapsed = true
                me.openInputGateIfReady(generation: gen)
            }
        }
        return true
    }

    private func handle(_ event: RFBEvent, from source: RFBClient, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .framebufferUpdated(let rects):
            if !sawFirstUpdate {
                sawFirstUpdate = true
                // Only a session that actually delivered a frame counts as a success for the backoff,
                // so a server that accepts and drops at once does not retry at full speed forever.
                reconnectPolicy.reset()
                openInputGateIfReady(generation: gen)
            }
            delegate?.session(self, didUpdate: source.framebuffer, rects: rects)
        case .desktopResized(let w, let h):
            delegate?.session(self, didResizeToWidth: w, height: h)
        case .cursorChanged(let c):
            delegate?.session(self, didChangeCursor: c)
        case .bell:
            delegate?.sessionDidRingBell(self)
        case .clipboard(let text):
            remoteClipboard = text
            delegate?.session(self, didReceiveClipboard: text)
        case .closed(let error):
            // nil = closed by us; that path already moved the state on.
            if let error { connectionEnded(error, generation: gen) }
        }
    }

    private func connectionEnded(_ error: RFBError, generation gen: Int) {
        guard gen == generation else { return }
        client?.disconnect()
        client = nil
        connectTask = nil
        closeInputGate()
        let failure = SessionErrorDescription.describe(error, hostKeyEvent: hostKeyEvent)
        if let delay = reconnectPolicy.nextDelay(after: failure.kind) {
            state = .waitingToReconnect(attempt: reconnectPolicy.attempts, delay: delay, reason: failure.message)
            retryTask = Task { [weak self] in
                let nanos = UInt64(max(0, delay) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                self?.retryAfterDelay(generation: gen)
            }
        } else {
            var f = failure
            if failure.kind == .transient {
                f.message = failure.message + "。已多次重连失败，请稍后点「重试」"
            }
            state = .failed(f)
        }
    }

    private func retryAfterDelay(generation gen: Int) {
        guard gen == generation, case .waitingToReconnect = state else { return }
        connect()
    }

    // MARK: - Host key (TOFU)

    private func makeVerifier(generation gen: Int) -> @Sendable (Data) async -> Bool {
        return { [weak self] publicKeyDER in
            guard let controller = self else { return false }
            return await controller.verifyHostKey(publicKeyDER, generation: gen)
        }
    }

    /// Checks a presented type 33 key against the pinned fingerprint; asks the delegate on first use.
    func verifyHostKey(_ publicKeyDER: Data, generation gen: Int) async -> Bool {
        guard gen == generation, let current = host else { return false }
        let fingerprint = AppleRSASecurityHandler.sha256Fingerprint(of: publicKeyDER)
        switch HostKeyTrust.evaluate(pinned: current.knownHostKeySHA256, presented: fingerprint) {
        case .trusted:
            return true
        case .mismatch:
            hostKeyEvent = .mismatch(presented: fingerprint)
            return false
        case .firstUse:
            guard let delegate else {
                hostKeyEvent = .declined
                return false
            }
            let accepted = await delegate.session(self, confirmNewHostKey: fingerprint)
            guard accepted, var updated = host else {
                if gen == generation { hostKeyEvent = .declined }
                return false
            }
            // The user approved this exact fingerprint: pin it even if the attempt that asked is
            // gone (the Mac timed out while the alert was open), so the retry does not ask again.
            if updated.knownHostKeySHA256 == nil {
                updated.knownHostKeySHA256 = fingerprint
                host = updated
                delegate.session(self, didPinHostKeyFor: updated)
            }
            return gen == generation && updated.knownHostKeySHA256 == fingerprint
        }
    }

    // MARK: - Input

    /// Sends the network actions (`.sendPointer`, `.sendScroll`) of a `PointerEngine` result; the
    /// UI handles the others. Dropped while not connected; held in order until input is ready.
    public func apply(_ actions: [PointerAction]) {
        guard client != nil, state.isConnected else { return }
        for action in actions {
            switch action {
            case .sendPointer(let x, let y, let buttons):
                pacer.enqueue(.pointer(x: x, y: y, buttons: buttons.rawValue))
            case .sendScroll(let x, let y, let dx, let dy, let buttons):
                pacer.enqueue(.scroll(x: x, y: y, deltaX: dx, deltaY: dy, buttons: buttons.rawValue))
            case .viewportChanged, .loupe, .feedback:
                break
            }
        }
    }

    /// Types text (soft keyboard), one keypress per character, each wrapped with the latched modifiers.
    public func typeText(_ text: String) {
        guard state.isConnected else { return }
        var latch = modifiers
        for group in KeyMapper.keystrokeGroups(for: text, shiftStrategy: shiftStrategy) {
            send(latch.wrap(group))
        }
        modifiers = latch
    }

    /// Types a secret (password / one-time code) without latched modifiers, optionally followed by
    /// Return. Returns false (and sends nothing) when not connected. The text is never logged.
    @discardableResult
    public func typeSecret(_ text: String, thenReturn: Bool) -> Bool {
        guard state.isConnected, client != nil else { return false }
        send(KeyMapper.keystrokes(for: text, shiftStrategy: shiftStrategy))
        if thenReturn { send(KeyMapper.keystroke(for: .returnKey)) }
        return true
    }

    /// Presses a special key, wrapped with the latched modifiers.
    public func press(_ key: SpecialKey) {
        guard state.isConnected else { return }
        var latch = modifiers
        send(latch.wrap(KeyMapper.keystroke(for: key)))
        modifiers = latch
    }

    /// Sends key events as they are (hardware keyboard: modifiers arrive as their own events).
    public func sendKeyEvents(_ events: [KeyEvent]) {
        guard state.isConnected else { return }
        send(events)
    }

    /// Toolbar modifier tap: off → one-shot → locked → off.
    public func tapModifier(_ key: ModifierKey) {
        var latch = modifiers
        latch.tap(key)
        modifiers = latch
    }

    public func resetModifiers() {
        var latch = modifiers
        latch.reset()
        modifiers = latch
    }

    /// Puts text on the Mac's clipboard (ClientCutText; Latin-1 only, others become "?").
    public func sendClipboard(_ text: String) {
        guard state.isConnected else { return }
        client?.sendClipboard(text)
    }

    public func requestFullUpdate() {
        guard state.isConnected else { return }
        client?.requestFullUpdate()
    }

    private func send(_ events: [KeyEvent]) {
        guard client != nil else { return }
        for e in events { pacer.enqueue(.key(keysym: e.keysym, down: e.down)) }
    }
}

extension RFBClient {
    /// Any error from `connect()` as an `RFBError`.
    static func describe(_ error: Error) -> RFBError {
        if let e = error as? RFBError { return e }
        if error is CancellationError { return .connectionClosed }
        return .connectionFailed(String(describing: error))
    }
}

// MARK: - Test hooks

extension SessionController {
    var testInProcessServer: MockRFBServer? { inProcessServer }
    var testGeneration: Int { generation }
    var testHostKeyEvent: HostKeyEvent? { hostKeyEvent }
}
