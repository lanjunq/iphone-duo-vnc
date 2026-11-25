import Foundation
import Testing
@testable import DuoVNCSession
import RFBCore
import RFBMockServer
import DuoVNCKit

@MainActor
final class RecordingDelegate: SessionControllerDelegate {
    var states: [SessionState] = []
    var updates = 0
    var lastFramebuffer: Framebuffer?
    var sizes: [String] = []
    var cursors = 0
    var bells = 0
    var clipboards: [String] = []
    var modifierChanges = 0
    var confirmAnswer = true
    var confirmations: [String] = []
    var pinned: [SavedHost] = []

    func session(_ session: SessionController, didChangeState state: SessionState) { states.append(state) }
    func session(_ session: SessionController, didUpdate framebuffer: Framebuffer, rects: [RFBRect]) {
        updates += 1
        lastFramebuffer = framebuffer
    }
    func session(_ session: SessionController, didResizeToWidth width: Int, height: Int) { sizes.append("\(width)x\(height)") }
    func session(_ session: SessionController, didChangeCursor cursor: RFBCursor) { cursors += 1 }
    func sessionDidRingBell(_ session: SessionController) { bells += 1 }
    func session(_ session: SessionController, didReceiveClipboard text: String) { clipboards.append(text) }
    func session(_ session: SessionController, didChangeModifiers latch: ModifierLatch) { modifierChanges += 1 }
    func session(_ session: SessionController, confirmNewHostKey fingerprint: String) async -> Bool {
        confirmations.append(fingerprint)
        return confirmAnswer
    }
    func session(_ session: SessionController, didPinHostKeyFor host: SavedHost) { pinned.append(host) }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Mock server with recording on and a small screen so tests are fast.
func smallMock(security: MockSecurity = .none) -> MockServerConfiguration {
    MockServerConfiguration(width: 320, height: 200, versionLine: "RFB 003.889\n", security: security)
}

/// The in-process server a controller created (via its first connection's events).
@MainActor
func keyEvents(_ server: MockRFBServer) -> [KeyEvent] {
    server.receivedEvents.compactMap { e -> KeyEvent? in
        if case .key(let k, let d) = e { return KeyEvent(keysym: k, down: d) }
        return nil
    }
}

@MainActor
@Suite(.serialized) struct SessionControllerTests {
    /// Builds a controller around a server the test can inspect.
    func make(_ config: MockServerConfiguration, credential: RFBCredential = .none,
              policy: ReconnectPolicy = ReconnectPolicy(schedule: [0.05], maxAttempts: 5))
        -> (SessionController, RecordingDelegate) {
        let c = SessionController(endpoint: .inProcess(config, credential: credential), reconnectPolicy: policy)
        let d = RecordingDelegate()
        c.delegate = d
        return (c, d)
    }

    func server(of c: SessionController) -> MockRFBServer? { c.testInProcessServer }

    @Test func connectsAndDeliversFrames() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        #expect(c.state.isConnected)
        #expect(d.sizes.first == "320x200")
        #expect(d.lastFramebuffer?.width == 320)
        #expect(d.states.first == .connecting(attempt: 0))
        if case .connected(let info) = c.state { #expect(info.serverVersion.contains("003.889")) }
        c.close()
        #expect(c.state == .closed)
        #expect(c.client == nil)
    }

    @Test func demoEndpointIs4K() async {
        let c = SessionController(endpoint: .demo)
        let d = RecordingDelegate()
        c.delegate = d
        c.start()
        #expect(await waitUntil(20) { d.updates > 0 })
        #expect(d.sizes.first == "3840x2160")
        #expect(SessionEndpoint.demo.isDemo)
        c.close()
    }

    @Test func inputWaitsForTheWarmupThenArrivesInOrder() async {
        // macOS drops input sent in the first ~2 s after connect; the controller must hold it.
        let (c, d) = make(smallMock())
        c.inputWarmup = 0.6
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        #expect(!c.isInputReady)
        c.typeText("Ab")
        c.apply([.sendPointer(x: 7, y: 9, buttons: [])])
        let s = server(of: c)!
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(keyEvents(s).isEmpty)                 // still inside the warm-up: nothing was sent
        #expect(c.pacer.pendingCount == 5)
        #expect(await waitUntil { c.isInputReady })
        #expect(await waitUntil { keyEvents(s).count == 4 })
        #expect(keyEvents(s) == [KeyEvent(keysym: 0x41, down: true), KeyEvent(keysym: 0x41, down: false),
                                 KeyEvent(keysym: 0x62, down: true), KeyEvent(keysym: 0x62, down: false)])
        c.close()
        #expect(!c.isInputReady)
    }

    @Test func queuedInputIsDroppedWhenTheConnectionGoesAway() async {
        let (c, d) = make(smallMock())
        c.inputWarmup = 30
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        #expect(c.typeSecret("hunter2", thenReturn: true))
        #expect(c.pacer.pendingCount == 16)
        c.suspend()
        #expect(c.pacer.pendingCount == 0)            // a password is never replayed into the next session
        c.close()
    }

    @Test func pointerActionsReachServer() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        c.apply([.sendPointer(x: 10, y: 20, buttons: [.left]), .sendPointer(x: 10, y: 20, buttons: []),
                 .loupe(visible: true), .sendScroll(x: 5, y: 6, deltaX: 0, deltaY: 2, buttons: [])])
        let s = server(of: c)!
        #expect(await waitUntil {
            s.receivedEvents.filter { if case .pointer = $0 { return true } else { return false } }.count >= 6
        })
        let pointers = s.receivedEvents.compactMap { e -> String? in
            if case .pointer(let x, let y, let b) = e { return "\(x),\(y),\(b.rawValue)" }
            return nil
        }
        #expect(pointers == ["10,20,1", "10,20,0", "5,6,16", "5,6,0", "5,6,16", "5,6,0"])
        c.close()
    }

    @Test func typingUsesLatchedModifiersOnce() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        c.tapModifier(.command)                       // one-shot ⌘
        #expect(c.modifiers.state(of: .command) == .oneShot)
        c.typeText("ca")
        #expect(c.modifiers.state(of: .command) == .off)
        c.press(.returnKey)
        let s = server(of: c)!
        #expect(await waitUntil { keyEvents(s).count >= 8 })
        let cmd: UInt32 = 0xffeb
        #expect(keyEvents(s) == [
            KeyEvent(keysym: cmd, down: true), KeyEvent(keysym: 0x63, down: true), KeyEvent(keysym: 0x63, down: false),
            KeyEvent(keysym: cmd, down: false),
            KeyEvent(keysym: 0x61, down: true), KeyEvent(keysym: 0x61, down: false),
            KeyEvent(keysym: 0xff0d, down: true), KeyEvent(keysym: 0xff0d, down: false),
        ])
        #expect(d.modifierChanges >= 2)
        c.close()
    }

    @Test func secretIgnoresModifiersAndAppendsReturn() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        c.tapModifier(.control)
        c.tapModifier(.control)                       // locked ⌃
        #expect(c.typeSecret("P1", thenReturn: true))
        let s = server(of: c)!
        #expect(await waitUntil { keyEvents(s).count >= 6 })
        #expect(keyEvents(s) == [
            KeyEvent(keysym: 0x50, down: true), KeyEvent(keysym: 0x50, down: false),
            KeyEvent(keysym: 0x31, down: true), KeyEvent(keysym: 0x31, down: false),
            KeyEvent(keysym: 0xff0d, down: true), KeyEvent(keysym: 0xff0d, down: false),
        ])
        #expect(c.modifiers.state(of: .control) == .locked)   // untouched by the secret
        // Nothing went to the clipboard.
        #expect(!s.receivedEvents.contains { if case .cutText = $0 { return true } else { return false } })
        c.close()
    }

    @Test func explicitShiftStrategy() async {
        let (c, d) = make(smallMock())
        c.shiftStrategy = .explicitShift
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        c.typeSecret("A", thenReturn: false)
        let s = server(of: c)!
        #expect(await waitUntil { keyEvents(s).count >= 4 })
        #expect(keyEvents(s) == [KeyEvent(keysym: 0xffe1, down: true), KeyEvent(keysym: 0x41, down: true),
                                 KeyEvent(keysym: 0x41, down: false), KeyEvent(keysym: 0xffe1, down: false)])
        c.close()
    }

    @Test func inputDroppedWhileNotConnected() async {
        let (c, _) = make(smallMock())
        #expect(!c.typeSecret("x", thenReturn: false))
        c.tapModifier(.shift)
        c.typeText("abc")                              // not connected: one-shot not consumed
        #expect(c.modifiers.state(of: .shift) == .oneShot)
        c.apply([.sendPointer(x: 1, y: 1, buttons: [])])
        #expect(c.state == .idle)
    }

    @Test func wrongVNCPasswordFailsWithoutRetry() async {
        let (c, _) = make(smallMock(security: .vncPassword("secret")), credential: .vncPassword("wrong"))
        c.start()
        #expect(await waitUntil { if case .failed = c.state { return true } else { return false } })
        guard case .failed(let f) = c.state else { Issue.record("not failed"); return }
        #expect(f.kind == .authentication)
        #expect(f.message.contains("登录失败"))
        #expect(!f.message.contains("wrong"))
        c.close()
    }

    @Test func rightVNCPasswordConnects() async {
        let (c, d) = make(smallMock(security: .vncPassword("secret")), credential: .vncPassword("secret"))
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        c.close()
    }

    @Test func missingCredentialIsPermanent() async {
        let (c, _) = make(smallMock(security: .vncPassword("secret")), credential: .none)
        c.start()
        #expect(await waitUntil { if case .failed = c.state { return true } else { return false } })
        if case .failed(let f) = c.state {
            #expect(f.kind == .permanent)
            #expect(f.error == .noUsableSecurityType(offered: [2]))
        }
        c.close()
    }

    @Test func serverDropReconnectsAutomatically() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        let s = server(of: c)!
        let firstFramebuffer = d.lastFramebuffer
        s.disconnectAll()
        #expect(await waitUntil { d.states.contains { if case .waitingToReconnect = $0 { return true } else { return false } } })
        #expect(await waitUntil { c.state.isConnected && d.lastFramebuffer !== firstFramebuffer && d.updates >= 2 })
        #expect(d.states.contains(.connecting(attempt: 1)))
        #expect(s.connectionsServed >= 2)
        #expect(c.reconnectPolicy.attempts == 0)      // reset after the first frame
        c.close()
    }

    @Test func gaveUpAfterMaxAttempts() async {
        // A server that refuses everyone: version line garbage → protocol error is permanent; instead
        // use a policy with zero automatic attempts on a dropped session.
        let (c, d) = make(smallMock(), policy: ReconnectPolicy(schedule: [0.05], maxAttempts: 0))
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        server(of: c)!.disconnectAll()
        #expect(await waitUntil { if case .failed = c.state { return true } else { return false } })
        if case .failed(let f) = c.state {
            #expect(f.kind == .transient)
            #expect(f.message.contains("重试"))
        }
        // The user retries; it works again.
        c.retryNow()
        #expect(await waitUntil { c.state.isConnected })
        c.close()
    }

    @Test func suspendAndResume() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        c.suspend()
        #expect(c.state == .suspended)
        #expect(c.client == nil)
        let updatesBefore = d.updates
        c.resume()
        #expect(await waitUntil { c.state.isConnected && d.updates > updatesBefore })
        c.close()
        c.resume()                                     // closed stays closed
        #expect(c.state == .closed)
        c.retryNow()
        #expect(c.state == .closed)
    }

    @Test func clipboardAndBell() async {
        let (c, d) = make(smallMock())
        c.start()
        #expect(await waitUntil { d.updates > 0 })
        let s = server(of: c)!
        s.sendBell()
        s.sendServerCutText("hello")
        #expect(await waitUntil { d.bells == 1 && d.clipboards == ["hello"] })
        #expect(c.remoteClipboard == "hello")
        c.sendClipboard("from phone")
        #expect(await waitUntil { s.receivedEvents.contains(.cutText("from phone")) })
        c.close()
    }

    @Test func hudTexts() {
        #expect(SessionState.connecting(attempt: 0).hudText == "正在连接…")
        #expect(SessionState.connecting(attempt: 2).hudText!.contains("第 2 次"))
        #expect(SessionState.waitingToReconnect(attempt: 1, delay: 0.5, reason: "连接已断开").hudText!.contains("1 秒后"))
        #expect(SessionState.idle.hudText == nil)
        #expect(SessionState.connecting(attempt: 0).isBusy)
        #expect(!SessionState.closed.isBusy)
    }
}

@MainActor
@Suite struct HostKeyTrustFlowTests {
    let der = Data((0..<64).map { UInt8($0) })

    func remote(pinned: String?) -> (SessionController, RecordingDelegate) {
        let host = SavedHost(displayName: "mini", host: "100.100.20.30", username: "u", knownHostKeySHA256: pinned)
        let c = SessionController(endpoint: .remote(host: host, credential: .macAccount(username: "u", password: "p")))
        let d = RecordingDelegate()
        c.delegate = d
        return (c, d)
    }

    @Test func firstUseAsksAndPins() async {
        let (c, d) = remote(pinned: nil)
        let ok = await c.verifyHostKey(der, generation: c.testGeneration)
        #expect(ok)
        let fp = AppleRSASecurityHandler.sha256Fingerprint(of: der)
        #expect(d.confirmations == [fp])
        #expect(d.pinned.first?.knownHostKeySHA256 == fp)
        #expect(c.host?.knownHostKeySHA256 == fp)
        // Second time: trusted without asking.
        #expect(await c.verifyHostKey(der, generation: c.testGeneration))
        #expect(d.confirmations.count == 1)
    }

    @Test func declinedFirstUse() async {
        let (c, d) = remote(pinned: nil)
        d.confirmAnswer = false
        #expect(!(await c.verifyHostKey(der, generation: c.testGeneration)))
        #expect(d.pinned.isEmpty)
        #expect(c.testHostKeyEvent == .declined)
    }

    @Test func mismatchBlocksWithoutAsking() async {
        let (c, d) = remote(pinned: String(repeating: "0", count: 64))
        #expect(!(await c.verifyHostKey(der, generation: c.testGeneration)))
        #expect(d.confirmations.isEmpty)
        let fp = AppleRSASecurityHandler.sha256Fingerprint(of: der)
        #expect(c.testHostKeyEvent == .mismatch(presented: fp))
        let f = SessionErrorDescription.describe(.hostKeyRejected, hostKeyEvent: c.testHostKeyEvent)
        #expect(f.kind == .hostKey)
        #expect(f.message.contains(HostKeyTrust.formatted(fp)))
    }

    @Test func staleGenerationRejected() async {
        let (c, d) = remote(pinned: nil)
        #expect(!(await c.verifyHostKey(der, generation: c.testGeneration + 1)))
        #expect(d.confirmations.isEmpty)
    }

    @Test func remoteConnectFailureIsTransient() async {
        // Nothing listens on port 1 of loopback: connection refused → transient → waiting to reconnect.
        let host = SavedHost(displayName: "x", host: "127.0.0.1", port: 1, authKind: .vncPassword)
        let c = SessionController(endpoint: .remote(host: host, credential: .vncPassword("x")),
                                  reconnectPolicy: ReconnectPolicy(schedule: [5], maxAttempts: 1))
        c.start()
        #expect(await waitUntil { if case .waitingToReconnect = c.state { return true } else { return false } })
        c.close()
    }
}

@Suite struct ErrorDescriptionTests {
    @Test func kinds() {
        #expect(SessionErrorDescription.describe(.connectionClosed).kind == .transient)
        #expect(SessionErrorDescription.describe(.timeout).kind == .transient)
        #expect(SessionErrorDescription.describe(.connectionFailed("refused")).kind == .transient)
        #expect(SessionErrorDescription.describe(.authenticationFailed(nil)).kind == .authentication)
        #expect(SessionErrorDescription.describe(.authenticationFailed("bad")).message.contains("bad"))
        #expect(SessionErrorDescription.describe(.hostKeyRejected).kind == .hostKey)
        #expect(SessionErrorDescription.describe(.hostKeyRejected, hostKeyEvent: .declined).message.contains("没有信任"))
        #expect(SessionErrorDescription.describe(.noUsableSecurityType(offered: [30, 33])).message.contains("30, 33"))
        #expect(SessionErrorDescription.describe(.protocolViolation("x")).kind == .permanent)
        #expect(SessionErrorDescription.describe(.unsupportedEncoding(99)).kind == .permanent)
        #expect(SessionErrorDescription.describe(.cryptoFailed("x")).kind == .permanent)
        #expect(SessionErrorDescription.describe(.decodeFailed("x")).kind == .transient)
        #expect(SessionErrorDescription.describe(.unsupportedProtocolVersion("x")).kind == .permanent)
    }
}
