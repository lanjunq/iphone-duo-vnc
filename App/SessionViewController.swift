import UIKit
import DuoVNCKit
import DuoVNCSession
import RFBCore

/// Root view of the session screen. Reads the reserved regions (fold, cameras) in
/// `updateConstraints()`, which UIKit re-runs when those regions change (see DuoHardware.swift).
final class SessionRootView: UIView {
    var onRegionsChanged: (() -> Void)?
    private(set) var regions: ReservedLayoutRegions = ReservedLayoutRegions()

    override class var requiresConstraintBasedLayout: Bool { true }

    override func updateConstraints() {
        let current: ReservedLayoutRegions = DuoHardware.reservedRegions(in: self)
        if current != regions {
            regions = current
            onRegionsChanged?()
        }
        super.updateConstraints()
    }
}

/// The full-screen remote desktop: Metal framebuffer + local cursor + loupe, gestures → `PointerEngine`
/// → `SessionController`, and the toolbar. All layout decisions come from DuoVNCKit
/// (`LayoutEngine`, `ToolbarLayout`, `LoupeGeometry`); this class only wires UIKit to them.
final class SessionViewController: UIViewController, SessionControllerDelegate, UIGestureRecognizerDelegate {
    var onClose: (() -> Void)?
    var onPinHost: ((SavedHost) -> Void)?

    private let session: SessionController
    private let sessionTitle: String
    private let settings: SessionSettings
    private var engine: PointerEngine

    private let rootView: SessionRootView = SessionRootView(frame: .zero)
    private let desktopView: UIView = UIView(frame: .zero)
    private let framebufferView: FramebufferMetalView = FramebufferMetalView(frame: .zero)
    private let cursorView: CursorOverlayView = CursorOverlayView(frame: .zero)
    private let loupeView: LoupeView = LoupeView(frame: .zero)
    private let toolbar: SessionToolbarView = SessionToolbarView(frame: .zero)
    private let hud: ConnectionHUDView = ConnectionHUDView(frame: .zero)
    private let keyInput: KeyInputView = KeyInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let toastLabel: UILabel = UILabel(frame: .zero)
    private let networkMonitor: NetworkMonitor = NetworkMonitor()
    private var hingeInteraction: AnyObject?

    private var keyboardHeight: CGFloat = 0
    private var remoteSize: CGSize = CGSize(width: 1920, height: 1080)
    private weak var currentFramebuffer: Framebuffer?
    private var loupeShown: Bool = false
    private var overflow: [ToolbarCommand] = []
    private var pressedHardwareKeys: [Int: [UInt32]] = [:]
    private var pendingHostKeyDecision: CheckedContinuation<Bool, Never>?
    /// The trust alert that `pendingHostKeyDecision` belongs to (nil once answered or superseded).
    private var hostKeyAlert: UIAlertController?
    private var isShutDown: Bool = false
    private var hasConnectedOnce: Bool = false
    private var toastGeneration: Int = 0

    private let impact: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback: UISelectionFeedbackGenerator = UISelectionFeedbackGenerator()
    private let notificationFeedback: UINotificationFeedbackGenerator = UINotificationFeedbackGenerator()

    private static let loupeSize: CGFloat = 150

    init(endpoint: SessionEndpoint, title: String, settings: SessionSettings) {
        self.session = SessionController(endpoint: endpoint)
        self.sessionTitle = title
        self.settings = settings
        var configuration: PointerEngineConfiguration = PointerEngineConfiguration()
        configuration.naturalScrolling = settings.naturalScrolling
        configuration.directTapMinZoom = settings.directTapZoom
        configuration.toggleZoomLevel = settings.directTapZoom
        let initial: Viewport = Viewport(remoteSize: CGSize(width: 1920, height: 1080), viewSize: CGSize(width: 1, height: 1))
        self.engine = PointerEngine(viewport: initial, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        session.shiftStrategy = settings.explicitShift ? ShiftStrategy.explicitShift : ShiftStrategy.keysymOnly
        session.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View lifecycle

    override func loadView() {
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rootView.backgroundColor = .black
        rootView.onRegionsChanged = { [weak self] in
            self?.view.setNeedsLayout()
        }

        desktopView.backgroundColor = .black
        desktopView.clipsToBounds = true
        desktopView.isMultipleTouchEnabled = true
        desktopView.addSubview(framebufferView)
        desktopView.addSubview(cursorView)
        loupeView.isHidden = true
        desktopView.addSubview(loupeView)
        rootView.addSubview(desktopView)
        rootView.addSubview(toolbar)
        rootView.addSubview(keyInput)

        hud.translatesAutoresizingMaskIntoConstraints = false
        desktopView.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: desktopView.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: desktopView.centerYAnchor),
            hud.widthAnchor.constraint(lessThanOrEqualTo: desktopView.widthAnchor, constant: -32),
            hud.heightAnchor.constraint(lessThanOrEqualTo: desktopView.heightAnchor, constant: -16),
        ])
        hud.onRetry = { [weak self] in
            self?.session.retryNow()
        }
        hud.onClose = { [weak self] in
            self?.closeTapped()
        }
        hud.show(SessionState.connecting(attempt: 0))

        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        toastLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.layer.cornerRadius = 10
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false
        desktopView.addSubview(toastLabel)

        toolbar.onCommand = { [weak self] (command: ToolbarCommand) in
            self?.perform(command)
        }
        toolbar.onOverflowChanged = { [weak self] (hidden: [ToolbarCommand]) in
            self?.overflow = hidden
            self?.rebuildMoreMenu()
        }
        rebuildMoreMenu()

        keyInput.onText = { [weak self] (text: String) in
            self?.session.typeText(text)
        }
        keyInput.onBackspace = { [weak self] in
            self?.session.press(SpecialKey.backspace)
        }
        keyInput.onHardwareKey = { [weak self] (keysym: UInt32, down: Bool) in
            self?.session.sendKeyEvents([KeyEvent(keysym: keysym, down: down)])
        }

        installGestures()

        let center: NotificationCenter = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground(_:)),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground(_:)),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)

        networkMonitor.onPathUsable = { [weak self] in
            self?.session.networkBecameAvailable()
        }
        networkMonitor.start()

        hingeInteraction = DuoHardware.observeHinge(on: rootView, onChange: { [weak self] in
            self?.rootView.setNeedsUpdateConstraints()
            self?.view.setNeedsLayout()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !keyInput.isFirstResponder {
            _ = becomeFirstResponder()
        }
        impact.prepare()
        session.start()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        rootView.setNeedsUpdateConstraints()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSession()
    }

    /// Ends the session (disconnect button, HUD 返回, or SwiftUI dismantling the screen). Idempotent.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        releaseHardwareKeys()
        apply(engine.cancel())
        session.close()
        networkMonitor.stop()
        resolveHostKeyDecision(false)
        if keyInput.isFirstResponder {
            keyInput.resignFirstResponder()
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func closeTapped() {
        shutdown()
        onClose?()
    }

    // MARK: - Layout

    private func layoutSession() {
        let insets: UIEdgeInsets = view.safeAreaInsets
        let regions: ReservedLayoutRegions = rootView.regions
        let aspect: CGFloat = remoteSize.height > 0 ? remoteSize.width / remoteSize.height : 16.0 / 9.0
        let input: LayoutEngine.Input = LayoutEngine.Input(
            bounds: view.bounds,
            safeAreaInsets: LayoutInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right),
            obstructedRects: regions.occlusions,
            remoteAspectRatio: aspect,
            keyboardHeight: keyboardHeight)
        let output: LayoutEngine.Output = LayoutEngine.layout(input, divisions: regions.divisions)

        desktopView.frame = output.desktopFrame
        framebufferView.frame = desktopView.bounds
        cursorView.frame = desktopView.bounds
        toolbar.frame = output.toolbarFrame
        let origin: CGPoint = output.toolbarFrame.origin
        let keepOut: [CGRect] = output.toolbarKeepOutRects.map { (r: CGRect) -> CGRect in
            CGRect(x: r.minX - origin.x, y: r.minY - origin.y, width: r.width, height: r.height)
        }
        toolbar.configure(axis: output.axis, keepOut: keepOut)
        apply(engine.setViewSize(desktopView.bounds.size))
        layoutToast()
    }

    // MARK: - Pointer

    private func installGestures() {
        let tap: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1

        let twoFingerTap: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress: UILongPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 12
        longPress.numberOfTouchesRequired = 1

        let aim: UIPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleAim(_:)))
        aim.minimumNumberOfTouches = 1
        aim.maximumNumberOfTouches = 1
        aim.require(toFail: longPress)

        let scroll: UIPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2

        let pinch: UIPinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        let all: [UIGestureRecognizer] = [tap, twoFingerTap, longPress, aim, scroll, pinch]
        for recognizer in all {
            recognizer.delegate = self
            desktopView.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Leave the HUD's buttons alone.
        if !hud.isHidden, let touched = touch.view, touched.isDescendant(of: hud) {
            return false
        }
        return true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        apply(engine.tap(at: recognizer.location(in: desktopView)))
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        apply(engine.twoFingerTap())
    }

    @objc private func handleAim(_ recognizer: UIPanGestureRecognizer) {
        let location: CGPoint = recognizer.location(in: desktopView)
        switch recognizer.state {
        case .began:
            // Where the finger first touched = current location minus the recognizer's threshold travel.
            let t: CGPoint = recognizer.translation(in: desktopView)
            apply(engine.aimBegan(at: CGPoint(x: location.x - t.x, y: location.y - t.y)))
            apply(engine.aimChanged(to: location))
        case .changed:
            apply(engine.aimChanged(to: location))
        case .ended, .cancelled, .failed:
            apply(engine.aimEnded())
        default:
            break
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let location: CGPoint = recognizer.location(in: desktopView)
        switch recognizer.state {
        case .began:
            apply(engine.dragBegan(at: location))
        case .changed:
            apply(engine.dragChanged(to: location))
        case .ended, .cancelled, .failed:
            apply(engine.dragEnded())
        default:
            break
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            apply(engine.scrollBegan())
            recognizer.setTranslation(CGPoint.zero, in: desktopView)
        case .changed:
            let t: CGPoint = recognizer.translation(in: desktopView)
            recognizer.setTranslation(CGPoint.zero, in: desktopView)
            apply(engine.scrollChanged(by: CGVector(dx: t.x, dy: t.y)))
        case .ended, .cancelled, .failed:
            apply(engine.scrollEnded())
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let location: CGPoint = recognizer.location(in: desktopView)
        switch recognizer.state {
        case .began:
            apply(engine.pinchBegan(centroid: location))
        case .changed:
            guard recognizer.numberOfTouches >= 2 else { return }
            apply(engine.pinchChanged(scale: recognizer.scale, centroid: location))
        case .ended, .cancelled, .failed:
            apply(engine.pinchEnded())
        default:
            break
        }
    }

    /// Sends the network part of the actions and applies the rest to the UI.
    private func apply(_ actions: [PointerAction]) {
        session.apply(actions)
        for action in actions {
            switch action {
            case .loupe(let visible):
                loupeShown = visible
                loupeView.isHidden = !visible
            case .feedback(let kind):
                giveFeedback(kind)
            case .sendPointer, .sendScroll, .viewportChanged:
                break
            }
        }
        syncViewport()
    }

    private func syncViewport() {
        let viewport: Viewport = engine.viewport
        framebufferView.setViewport(viewport)
        cursorView.place(at: engine.cursorViewPoint, viewportScale: viewport.scale)
        toolbar.setZoomedIn(viewport.isValid && !viewport.isFitted)
        if loupeShown {
            updateLoupe()
        }
    }

    private func updateLoupe() {
        let viewport: Viewport = engine.viewport
        let frame: CGRect = LoupeGeometry.frame(cursorView: engine.cursorViewPoint, bounds: desktopView.bounds,
                                                size: SessionViewController.loupeSize)
        loupeView.frame = frame
        let side: CGFloat = LoupeGeometry.sourceSide(loupeSize: frame.width, viewportScale: viewport.scale)
        let pixel: (x: Int, y: Int) = engine.cursorPixel
        let source: CGRect = LoupeGeometry.sourceRect(cursorPixel: pixel, remoteSize: viewport.remoteSize, side: side)
        loupeView.update(framebuffer: currentFramebuffer, source: source, cursorPixel: pixel)
    }

    private func giveFeedback(_ kind: PointerFeedback) {
        switch kind {
        case .click, .doubleClick, .rightClick:
            impact.impactOccurred()
        case .dragBegan, .dragEnded:
            impact.impactOccurred(intensity: 0.6)
        case .aimed:
            selectionFeedback.selectionChanged()
        }
    }

    // MARK: - Toolbar

    private func perform(_ command: ToolbarCommand) {
        switch command {
        case .click:
            apply(engine.click())
        case .rightClick:
            apply(engine.rightClick())
        case .doubleClick:
            apply(engine.doubleClick())
        case .keyboard:
            toggleKeyboard()
        case .password:
            presentSecureEntry()
        case .zoom:
            apply(engine.toggleZoom())
        case .more:
            break
        case .disconnect:
            closeTapped()
        case .escape, .tab, .returnKey, .left, .up, .down, .right:
            if let key = command.specialKey {
                session.press(key)
            }
        case .command, .option, .control, .shift:
            if let modifier = command.modifier {
                session.tapModifier(modifier)
            }
        }
    }

    private func toggleKeyboard() {
        if keyInput.isFirstResponder {
            keyInput.resignFirstResponder()
            _ = becomeFirstResponder()
        } else {
            _ = keyInput.becomeFirstResponder()
        }
        toolbar.setKeyboardShown(keyInput.isFirstResponder)
    }

    private func rebuildMoreMenu() {
        var children: [UIMenuElement] = []

        let hiddenCommands: [ToolbarCommand] = overflow.filter { (c: ToolbarCommand) -> Bool in c != .more }
        if !hiddenCommands.isEmpty {
            let actions: [UIAction] = hiddenCommands.map { (command: ToolbarCommand) -> UIAction in
                UIAction(title: menuTitle(for: command), handler: { [weak self] (_: UIAction) in
                    self?.perform(command)
                })
            }
            children.append(UIMenu(title: "", options: .displayInline, children: actions))
        }

        let functionKeys: [SpecialKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
        var functionActions: [UIAction] = []
        for (index, key) in functionKeys.enumerated() {
            functionActions.append(UIAction(title: "F\(index + 1)", handler: { [weak self] (_: UIAction) in
                self?.session.press(key)
            }))
        }
        children.append(UIMenu(title: "功能键 F1–F12", children: functionActions))

        let otherKeys: [(String, SpecialKey)] = [("退格 ⌫", .backspace), ("向前删除 ⌦", .forwardDelete), ("空格", .space),
                                                 ("Home", .home), ("End", .end), ("Page Up", .pageUp), ("Page Down", .pageDown)]
        let otherActions: [UIAction] = otherKeys.map { (entry: (String, SpecialKey)) -> UIAction in
            let key: SpecialKey = entry.1
            return UIAction(title: entry.0, handler: { [weak self] (_: UIAction) in
                self?.session.press(key)
            })
        }
        children.append(UIMenu(title: "其他按键", children: otherActions))

        children.append(UIAction(title: "把 iPhone 剪贴板发到 Mac", image: UIImage(systemName: "arrow.up.doc.on.clipboard"),
                                 handler: { [weak self] (_: UIAction) in self?.sendLocalClipboard() }))
        children.append(UIAction(title: "拷贝 Mac 剪贴板到 iPhone", image: UIImage(systemName: "doc.on.clipboard"),
                                 handler: { [weak self] (_: UIAction) in self?.copyRemoteClipboard() }))
        children.append(UIAction(title: "解除所有修饰键", image: UIImage(systemName: "command"),
                                 handler: { [weak self] (_: UIAction) in self?.session.resetModifiers() }))
        children.append(UIAction(title: "刷新画面", image: UIImage(systemName: "arrow.clockwise"),
                                 handler: { [weak self] (_: UIAction) in self?.session.requestFullUpdate() }))
        children.append(UIAction(title: "连接信息", image: UIImage(systemName: "info.circle"),
                                 handler: { [weak self] (_: UIAction) in self?.showConnectionInfo() }))
        toolbar.setMoreMenu(UIMenu(title: "", children: children))
    }

    private func menuTitle(for command: ToolbarCommand) -> String {
        switch command {
        case .left: return "← 左方向键"
        case .right: return "→ 右方向键"
        case .up: return "↑ 上方向键"
        case .down: return "↓ 下方向键"
        case .returnKey: return "回车"
        case .command: return "⌘ Command（锁存）"
        case .option: return "⌥ Option（锁存）"
        case .control: return "⌃ Control（锁存）"
        case .shift: return "⇧ Shift（锁存）"
        default: return command.title
        }
    }

    private func sendLocalClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            showToast("iPhone 剪贴板里没有文字")
            return
        }
        guard session.state.isConnected else {
            showToast("还没连上 Mac")
            return
        }
        session.sendClipboard(text)
        let latin1: Bool = text.unicodeScalars.allSatisfy { (s: Unicode.Scalar) -> Bool in s.value <= 0xff }
        showToast(latin1 ? "已发到 Mac 剪贴板" : "已发到 Mac 剪贴板（中文等字符会变成 ?，这是 VNC 协议的限制）")
    }

    private func copyRemoteClipboard() {
        guard let text = session.remoteClipboard, !text.isEmpty else {
            showToast("还没收到 Mac 的剪贴板内容")
            return
        }
        UIPasteboard.general.string = text
        showToast("已拷贝到 iPhone 剪贴板")
    }

    private func showConnectionInfo() {
        var lines: [String] = ["主机：\(sessionTitle)"]
        if let info = session.serverInfo {
            lines.append("名称：\(info.name)")
            lines.append("协议：\(info.serverVersion.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("登录方式：类型 \(info.securityType)")
            lines.append("屏幕：\(info.width)×\(info.height)")
        }
        if let stats = session.statistics {
            lines.append("收到：\(stats.bytesReceived / 1024) KB，发送：\(stats.bytesSent / 1024) KB")
            lines.append("画面更新：\(stats.updates) 次，矩形 \(stats.rects) 个")
            let encodings: [String] = stats.rectsByEncoding.keys.sorted().map { (k: Int32) -> String in
                "\(SessionViewController.encodingName(k))×\(stats.rectsByEncoding[k] ?? 0)"
            }
            if !encodings.isEmpty { lines.append("编码：" + encodings.joined(separator: "，")) }
            if let start = stats.connectStartedAt, let first = stats.firstUpdateAt {
                lines.append(String(format: "首帧用时：%.2f 秒", first.timeIntervalSince(start)))
            }
        }
        let alert: UIAlertController = UIAlertController(title: "连接信息", message: lines.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
        topPresenter().present(alert, animated: true, completion: nil)
    }

    private static func encodingName(_ encoding: Int32) -> String {
        switch encoding {
        case 0: return "Raw"
        case 1: return "CopyRect"
        case 2: return "RRE"
        case 5: return "Hextile"
        case 6: return "Zlib"
        case 7: return "Tight"
        case 16: return "ZRLE"
        case -239: return "光标"
        case -223: return "改尺寸"
        case -224: return "LastRect"
        default: return "\(encoding)"
        }
    }

    // MARK: - Secure entry

    private func presentSecureEntry() {
        let keyboardWasShown: Bool = keyInput.isFirstResponder
        let entry: SecureEntryViewController = SecureEntryViewController()
        entry.onSend = { [weak self] (text: String, pressReturn: Bool) -> Bool in
            guard let self = self else { return false }
            return self.session.typeSecret(text, thenReturn: pressReturn)
        }
        entry.onDismiss = { [weak self] in
            guard let self = self else { return }
            if keyboardWasShown {
                _ = self.keyInput.becomeFirstResponder()
            } else {
                _ = self.becomeFirstResponder()
            }
            self.toolbar.setKeyboardShown(self.keyInput.isFirstResponder)
        }
        entry.modalPresentationStyle = .pageSheet
        if let sheet = entry.sheetPresentationController {
            sheet.detents = [UISheetPresentationController.Detent.medium(), UISheetPresentationController.Detent.large()]
            sheet.prefersGrabberVisible = true
        }
        topPresenter().present(entry, animated: true, completion: nil)
    }

    private func topPresenter() -> UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Hardware keyboard (when the session view controller is first responder)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled: Set<UIPress> = handleHardwarePresses(presses, down: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled: Set<UIPress> = handleHardwarePresses(presses, down: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled: Set<UIPress> = handleHardwarePresses(presses, down: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func handleHardwarePresses(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage: Int = key.keyCode.rawValue
            if down {
                // While the soft-keyboard responder is active, text keys already arrive through
                // `insertText` (and non-text keys through KeyInputView). Forwarding them here as well
                // would type every character twice, so only ⌘/⌃/⇧ and ⌘/⌃ shortcuts are taken here.
                if keyInput.isFirstResponder && !takesWhileTyping(key: key, usage: usage) {
                    unhandled.insert(press)
                    continue
                }
                guard session.state.isConnected else {
                    unhandled.insert(press)
                    continue
                }
                var keysyms: [UInt32] = []
                if let special = HardwareKeyMap.keysym(forHIDUsage: usage) {
                    keysyms = [special]
                } else {
                    let flags: UIKeyModifierFlags = key.modifierFlags
                    let held: Bool = flags.contains(.command) || flags.contains(.control) || flags.contains(.alternate)
                    keysyms = HardwareKeyMap.characterKeysyms(characters: key.characters,
                                                              charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                                              commandControlOrOptionHeld: held)
                }
                if keysyms.isEmpty {
                    unhandled.insert(press)
                    continue
                }
                pressedHardwareKeys[usage] = keysyms
                session.sendKeyEvents(keysyms.map { (k: UInt32) -> KeyEvent in KeyEvent(keysym: k, down: true) })
            } else {
                if let keysyms = pressedHardwareKeys.removeValue(forKey: usage) {
                    session.sendKeyEvents(keysyms.reversed().map { (k: UInt32) -> KeyEvent in KeyEvent(keysym: k, down: false) })
                } else {
                    unhandled.insert(press)
                }
            }
        }
        return unhandled
    }

    /// Hardware presses the view controller forwards while `keyInput` is first responder: the ⌘, ⌃ and
    /// ⇧ modifiers themselves, and character keys with ⌘ or ⌃ held (those never reach `insertText`).
    /// ⌥ is left to the text path, which already delivers the composed character.
    private func takesWhileTyping(key: UIKey, usage: Int) -> Bool {
        switch usage {
        case 0xE0, 0xE4, 0xE1, 0xE5, 0xE3, 0xE7:
            return true
        default:
            if HardwareKeyMap.isModifier(usage: usage) { return false }
            let flags: UIKeyModifierFlags = key.modifierFlags
            return flags.contains(.command) || flags.contains(.control)
        }
    }

    /// Releases every hardware key still held on the Mac (backgrounding, closing).
    private func releaseHardwareKeys() {
        for (_, keysyms) in pressedHardwareKeys {
            session.sendKeyEvents(keysyms.reversed().map { (k: UInt32) -> KeyEvent in KeyEvent(keysym: k, down: false) })
        }
        pressedHardwareKeys.removeAll()
    }

    // MARK: - Notifications

    @objc private func appDidEnterBackground(_ notification: Notification) {
        releaseHardwareKeys()
        apply(engine.cancel())
        session.suspend()
    }

    @objc private func appWillEnterForeground(_ notification: Notification) {
        session.resume()
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let screenFrame: CGRect = value.cgRectValue
        let local: CGRect
        if let space = view.window?.windowScene?.screen.coordinateSpace {
            local = view.convert(screenFrame, from: space)
        } else {
            local = screenFrame
        }
        let height: CGFloat = (local.isEmpty || local.minY >= view.bounds.maxY) ? 0 : max(0, view.bounds.maxY - local.minY)
        if abs(height - keyboardHeight) > 0.5 {
            keyboardHeight = height
            view.setNeedsLayout()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        if keyboardHeight != 0 {
            keyboardHeight = 0
            view.setNeedsLayout()
        }
    }

    // MARK: - Toast

    private func showToast(_ text: String) {
        toastGeneration += 1
        let generation: Int = toastGeneration
        toastLabel.text = text
        layoutToast()
        UIView.animate(withDuration: 0.2) {
            self.toastLabel.alpha = 1
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self = self, self.toastGeneration == generation else { return }
            UIView.animate(withDuration: 0.3) {
                self.toastLabel.alpha = 0
            }
        }
    }

    private func layoutToast() {
        let maxWidth: CGFloat = max(80, desktopView.bounds.width - 40)
        let fitted: CGSize = toastLabel.sizeThatFits(CGSize(width: maxWidth - 24, height: CGFloat.greatestFiniteMagnitude))
        let width: CGFloat = min(maxWidth, fitted.width + 24)
        let height: CGFloat = fitted.height + 14
        toastLabel.frame = CGRect(x: (desktopView.bounds.width - width) / 2, y: 12, width: width, height: height)
    }

    // MARK: - SessionControllerDelegate

    func session(_ session: SessionController, didChangeState state: SessionState) {
        hud.show(state)
        if !state.isConnected {
            // A drop in the middle of a drag must not leave the engine thinking a button is held.
            releaseHardwareKeys()
            apply(engine.cancel())
        }
        if case .connected = state, !hasConnectedOnce {
            hasConnectedOnce = true
            showToast("已连接 \(sessionTitle)。轻点移动光标，再按「点击」；双指滑动滚动，捏合缩放")
            #if DEBUG
            if session.endpoint.isDemo && ProcessInfo.processInfo.arguments.contains("-DuoVNCSelfTest") {
                runDemoSelfTest()
            }
            #endif
        }
    }

    func session(_ session: SessionController, didUpdate framebuffer: Framebuffer, rects: [RFBRect]) {
        currentFramebuffer = framebuffer
        framebufferView.update(from: framebuffer, rects: rects)
        if loupeShown {
            updateLoupe()
        }
    }

    func session(_ session: SessionController, didResizeToWidth width: Int, height: Int) {
        let size: CGSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        guard size.width > 0, size.height > 0 else { return }
        if size != remoteSize || engine.viewport.remoteSize != size {
            remoteSize = size
            apply(engine.setRemoteSize(size))
            view.setNeedsLayout()
        }
    }

    func session(_ session: SessionController, didChangeCursor cursor: RFBCursor) {
        cursorView.setRemoteCursor(cursor)
        syncViewport()
    }

    func sessionDidRingBell(_ session: SessionController) {
        notificationFeedback.notificationOccurred(.warning)
    }

    func session(_ session: SessionController, didReceiveClipboard text: String) {
        showToast("Mac 剪贴板有新内容，可在「更多」里拷贝到 iPhone")
    }

    func session(_ session: SessionController, didChangeModifiers latch: ModifierLatch) {
        toolbar.setModifiers(latch)
    }

    func session(_ session: SessionController, confirmNewHostKey fingerprint: String) async -> Bool {
        if isShutDown { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // A newer attempt (e.g. the Mac timed out while the old alert was open) supersedes the old
            // question: answer it "no" and take its alert down, so its buttons can never answer this one.
            let previous: UIAlertController? = self.hostKeyAlert
            self.resolveHostKeyDecision(false)
            self.pendingHostKeyDecision = continuation
            let message: String = "第一次连接这台 Mac。它的密钥指纹（SHA-256）是：\n\n\(HostKeyTrust.formatted(fingerprint))\n\n如果这是你自己的 Mac（通过 Tailscale 或家里网络），可以信任。以后指纹变了会阻止连接并提示你。"
            let alert: UIAlertController = UIAlertController(title: "信任这台 Mac？", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: { [weak self, weak alert] (_: UIAlertAction) in
                guard let self = self, let alert = alert, self.hostKeyAlert === alert else { return }
                self.hostKeyAlert = nil
                self.resolveHostKeyDecision(false)
            }))
            alert.addAction(UIAlertAction(title: "信任并连接", style: .default, handler: { [weak self, weak alert] (_: UIAlertAction) in
                guard let self = self, let alert = alert, self.hostKeyAlert === alert else { return }
                self.hostKeyAlert = nil
                self.resolveHostKeyDecision(true)
            }))
            self.hostKeyAlert = alert
            if let previous = previous, previous.presentingViewController != nil {
                previous.dismiss(animated: false, completion: { [weak self] in
                    guard let self = self, self.hostKeyAlert === alert else { return }
                    self.topPresenter().present(alert, animated: true, completion: nil)
                })
            } else {
                self.topPresenter().present(alert, animated: true, completion: nil)
            }
        }
    }

    func session(_ session: SessionController, didPinHostKeyFor host: SavedHost) {
        onPinHost?(host)
        showToast("已记住这台 Mac 的指纹")
    }

    #if DEBUG
    /// Development aid (demo mode + `-DuoVNCSelfTest`): drives the real input path without touches —
    /// aims at the demo desktop's first "Click targets" button through the view, clicks via the toolbar
    /// command, latches ⇧ for one key, and types text, so a screenshot shows hits and typed characters.
    private func runDemoSelfTest() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self = self else { return }
            let viewport: Viewport = self.engine.viewport
            // Center of the dock, which DemoDesktopScene draws at the bottom middle of the screen.
            let remote: CGPoint = CGPoint(x: viewport.remoteSize.width / 2, y: viewport.remoteSize.height - 60)
            self.apply(self.engine.tap(at: viewport.viewPoint(forRemote: remote)))
            self.perform(ToolbarCommand.click)
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.perform(ToolbarCommand.shift)
            self.session.typeText("duo VNC 1+1=2")
            self.perform(ToolbarCommand.returnKey)
            _ = self.session.typeSecret("p@ss", thenReturn: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.apply(self.engine.aimBegan(at: CGPoint(x: self.desktopView.bounds.midX, y: self.desktopView.bounds.midY)))
            self.apply(self.engine.aimChanged(to: CGPoint(x: self.desktopView.bounds.midX + 40, y: self.desktopView.bounds.midY + 20)))
        }
    }
    #endif

    /// Answers the pending trust question. An alert still on screen (superseded, or the session
    /// closing) is only forgotten here; the caller dismisses it if needed.
    private func resolveHostKeyDecision(_ accepted: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = pendingHostKeyDecision
        pendingHostKeyDecision = nil
        hostKeyAlert = nil
        pending?.resume(returning: accepted)
    }
}
