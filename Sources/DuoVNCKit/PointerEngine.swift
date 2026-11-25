import Foundation
import CoreGraphics

/// Pointer button mask. Bit values are identical to RFC 6143 §7.5.5 (and `RFBButtonMask` in RFBBase),
/// so the app converts with `RFBButtonMask(rawValue: buttons.rawValue)`.
public struct PointerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = PointerButtons(rawValue: 1 << 0)
    public static let middle = PointerButtons(rawValue: 1 << 1)
    public static let right = PointerButtons(rawValue: 1 << 2)
}

/// Haptic / visual feedback the UI may give.
public enum PointerFeedback: Equatable, Sendable {
    /// The cursor was placed by a tap without clicking (aim mode).
    case aimed
    case click
    case doubleClick
    case rightClick
    /// Long-press drag pressed the left button.
    case dragBegan
    /// Long-press drag released the left button.
    case dragEnded
}

/// One thing for the UI to do, in order.
public enum PointerAction: Equatable, Sendable {
    /// Send a PointerEvent at remote pixel (x, y) with this button state.
    case sendPointer(x: Int, y: Int, buttons: PointerButtons)
    /// Send scroll-wheel clicks at remote pixel (x, y), with `buttons` held.
    /// Sign convention: `deltaY > 0` = wheel DOWN (RFB button 5, shows content further down),
    /// `deltaY < 0` = wheel UP (button 4); `deltaX > 0` = wheel RIGHT (button 7), `deltaX < 0` = LEFT (6).
    /// At most one of the axes is usually non-zero; magnitude = number of wheel clicks.
    case sendScroll(x: Int, y: Int, deltaX: Int, deltaY: Int, buttons: PointerButtons)
    /// The viewport changed; redraw with this value (also readable as `engine.viewport`).
    case viewportChanged(Viewport)
    /// Show or hide the magnifier loupe around the cursor.
    case loupe(visible: Bool)
    /// Give feedback (haptic tick etc.).
    case feedback(PointerFeedback)
}

/// Tunables for `PointerEngine`. All distances are in view points unless stated otherwise.
public struct PointerEngineConfiguration: Equatable, Sendable {
    /// Cursor movement = finger movement converted to remote pixels × `gain`. Default 0.5.
    public var gain: CGFloat
    /// On drag begin the cursor jumps to the finger position moved up by this many points, so the
    /// finger does not cover it. Default 0.
    public var aimVerticalOffset: CGFloat
    /// A one-finger tap clicks directly when `viewport.zoomRelativeToFit >= directTapMinZoom`;
    /// below that it only aims. Default 4.0.
    public var directTapMinZoom: CGFloat
    /// Finger travel (points) per scroll-wheel click. Default 12.
    public var scrollPointsPerStep: CGFloat
    /// Upper bound of wheel clicks emitted per axis for one gesture update (the rest is dropped). Default 10.
    public var maxScrollStepsPerUpdate: Int
    /// Natural (iOS-style) scrolling: moving the fingers up scrolls the content up, i.e. wheel down.
    /// Default true.
    public var naturalScrolling: Bool
    /// `ensureVisible` margin: the viewport follows the cursor so it stays this far inside the edges. Default 40.
    public var followMargin: CGFloat
    /// Zoom (relative to fit) used by `toggleZoom()` when zooming in. Default = 4.0 so taps then click.
    public var toggleZoomLevel: CGFloat

    public init(gain: CGFloat = 0.5, aimVerticalOffset: CGFloat = 0, directTapMinZoom: CGFloat = 4.0,
                scrollPointsPerStep: CGFloat = 12, maxScrollStepsPerUpdate: Int = 10,
                naturalScrolling: Bool = true, followMargin: CGFloat = 40, toggleZoomLevel: CGFloat = 4.0) {
        self.gain = gain
        self.aimVerticalOffset = aimVerticalOffset
        self.directTapMinZoom = directTapMinZoom
        self.scrollPointsPerStep = scrollPointsPerStep
        self.maxScrollStepsPerUpdate = maxScrollStepsPerUpdate
        self.naturalScrolling = naturalScrolling
        self.followMargin = followMargin
        self.toggleZoomLevel = toggleZoomLevel
    }
}

/// The "aim, then click" interaction model. Pure, deterministic, UIKit-free.
///
/// The UI feeds recognized gestures (view-space points of the desktop area) and toolbar commands;
/// each call returns the ordered `PointerAction`s to apply. The engine owns the remote cursor position
/// (continuous, in remote pixels), the held buttons and the `Viewport`.
///
/// State machine (`mode`):
/// - `.idle` — nothing in progress.
/// - `.aiming` — one-finger drag: cursor follows the finger with `gain`; loupe visible; ends without clicking.
/// - `.dragging` — long-press drag: left button held, cursor follows the finger; released on end/cancel.
/// - `.scrolling` — two-finger drag: wheel clicks at the cursor.
/// - `.pinching` — pinch: zoom around the centroid and pan with centroid movement.
/// Beginning any gesture or discrete command (tap, click...) first finishes the current one cleanly
/// (buttons released, loupe hidden), so a lost `ended` event can never leave the engine stuck. `changed`/`ended` events for a gesture that is not the current mode are ignored.
/// Coordinates sent are integer remote pixels: `floor` of the continuous cursor, which is clamped to
/// `[0, width-1] x [0, height-1]`.
public struct PointerEngine: Sendable {
    public enum Mode: Equatable, Sendable {
        case idle
        case aiming
        case dragging
        case scrolling
        case pinching
    }

    public var configuration: PointerEngineConfiguration
    public private(set) var viewport: Viewport
    public private(set) var mode: Mode = .idle
    /// Continuous cursor position in remote pixels (always clamped to the remote bounds).
    public private(set) var cursor: CGPoint
    /// Buttons currently held down on the remote side.
    public private(set) var buttons: PointerButtons = []

    private var lastFinger: CGPoint = .zero
    private var scrollRemainder: CGVector = .zero
    private var lastPinchScale: CGFloat = 1
    private var lastPinchCentroid: CGPoint = .zero
    private var lastSent: (x: Int, y: Int, buttons: PointerButtons)?

    public init(viewport: Viewport, configuration: PointerEngineConfiguration = PointerEngineConfiguration()) {
        self.viewport = viewport
        self.configuration = configuration
        // Start in the middle of the remote screen.
        self.cursor = CGPoint(x: viewport.remoteSize.width / 2, y: viewport.remoteSize.height / 2)
        self.cursor = clamped(cursor)
    }

    /// Integer remote pixel of the cursor (what is sent on the wire).
    public var cursorPixel: (x: Int, y: Int) { pixel(cursor) }

    /// View point of the center of the cursor's pixel, for drawing the local cursor/loupe.
    public var cursorViewPoint: CGPoint {
        let p = cursorPixel
        return viewport.viewPoint(forRemote: CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5))
    }

    /// Whether a one-finger tap would click right now (vs. only aim).
    public var tapClicksDirectly: Bool {
        viewport.zoomRelativeToFit >= configuration.directTapMinZoom - 1e-9
    }

    // MARK: - Viewport management

    /// The desktop area changed size (rotation, fold, keyboard).
    public mutating func setViewSize(_ size: CGSize) -> [PointerAction] {
        let before = viewport
        viewport.setViewSize(size)
        var out: [PointerAction] = []
        if viewport.zoomRelativeToFit > 1 + 1e-9 {
            viewport.ensureVisible(remotePoint: cursor, margin: configuration.followMargin)
        }
        if viewport != before { out.append(.viewportChanged(viewport)) }
        return out
    }

    /// The remote screen changed size (DesktopSize). Re-fits and clamps the cursor; sends nothing.
    public mutating func setRemoteSize(_ size: CGSize) -> [PointerAction] {
        viewport.setRemoteSize(size)
        cursor = clamped(cursor)
        lastSent = nil
        return [.viewportChanged(viewport)]
    }

    /// Show the whole screen.
    public mutating func fit() -> [PointerAction] {
        let before = viewport
        viewport.fit()
        return viewport != before ? [.viewportChanged(viewport)] : []
    }

    /// Toolbar fit/zoom toggle: if zoomed in → fit; if fitted → zoom to `toggleZoomLevel` centered on the cursor.
    public mutating func toggleZoom() -> [PointerAction] {
        let before = viewport
        if viewport.zoomRelativeToFit > 1 + 1e-6 {
            viewport.fit()
        } else {
            viewport.center(onRemote: cursor, zoomRelativeToFit: configuration.toggleZoomLevel)
        }
        return viewport != before ? [.viewportChanged(viewport)] : []
    }

    // MARK: - One-finger tap

    /// One-finger tap at a view point. Zoomed in enough → move there and left-click. Otherwise → aim only.
    public mutating func tap(at viewPoint: CGPoint) -> [PointerAction] {
        guard viewport.isValid, finite(viewPoint) else { return [] }
        let direct = tapClicksDirectly
        var out = finishCurrentMode()
        out += moveCursor(to: viewport.remotePoint(forView: viewPoint))
        if direct {
            out += clickSequence(.left, count: 1)
            out.append(.feedback(.click))
        } else {
            out.append(.feedback(.aimed))
        }
        return out
    }

    // MARK: - One-finger drag (aim)

    /// One-finger drag began. Pass the initial touch-down location (not the location after the
    /// recognizer's movement threshold) so the cursor lands where the finger first touched.
    public mutating func aimBegan(at viewPoint: CGPoint) -> [PointerAction] {
        guard viewport.isValid, finite(viewPoint) else { return [] }
        var out = finishCurrentMode()
        mode = .aiming
        lastFinger = viewPoint
        let target = CGPoint(x: viewPoint.x, y: viewPoint.y - configuration.aimVerticalOffset)
        out.append(.loupe(visible: true))
        out += moveCursor(to: viewport.remotePoint(forView: target))
        return out
    }

    /// One-finger drag moved to `viewPoint` (absolute location in the desktop view).
    public mutating func aimChanged(to viewPoint: CGPoint) -> [PointerAction] {
        guard mode == .aiming, finite(viewPoint) else { return [] }
        return followFinger(to: viewPoint)
    }

    /// One-finger drag ended: the cursor stays, nothing is clicked.
    public mutating func aimEnded() -> [PointerAction] {
        guard mode == .aiming else { return [] }
        mode = .idle
        return [.loupe(visible: false)]
    }

    // MARK: - Long-press drag

    /// Long press recognized: press the left button at the cursor (not at the finger).
    public mutating func dragBegan(at viewPoint: CGPoint) -> [PointerAction] {
        guard viewport.isValid, finite(viewPoint) else { return [] }
        var out = finishCurrentMode()
        mode = .dragging
        lastFinger = viewPoint
        buttons = [.left]
        out.append(.loupe(visible: true))
        out.append(sendPointerForced())
        out.append(.feedback(.dragBegan))
        return out
    }

    /// Long-press drag moved.
    public mutating func dragChanged(to viewPoint: CGPoint) -> [PointerAction] {
        guard mode == .dragging, finite(viewPoint) else { return [] }
        return followFinger(to: viewPoint)
    }

    /// Long-press drag ended (or was cancelled): release the left button at the cursor.
    public mutating func dragEnded() -> [PointerAction] {
        guard mode == .dragging else { return [] }
        return finishCurrentMode()
    }

    // MARK: - Two-finger scroll

    /// Two-finger drag began.
    public mutating func scrollBegan() -> [PointerAction] {
        let out = finishCurrentMode()
        mode = .scrolling
        scrollRemainder = .zero
        return out
    }

    /// Two-finger drag moved by `translation` points since the previous call (incremental, not cumulative).
    public mutating func scrollChanged(by translation: CGVector) -> [PointerAction] {
        guard mode == .scrolling, translation.dx.isFinite, translation.dy.isFinite else { return [] }
        let step = configuration.scrollPointsPerStep
        guard step.isFinite, step > 0 else { return [] }
        // Natural scrolling: fingers up (dy < 0) → wheel down (+). Traditional: fingers up → wheel up (-).
        let sign: CGFloat = configuration.naturalScrolling ? -1 : 1
        scrollRemainder.dx += translation.dx * sign
        scrollRemainder.dy += translation.dy * sign
        let sx = (scrollRemainder.dx / step).rounded(.towardZero)
        let sy = (scrollRemainder.dy / step).rounded(.towardZero)
        scrollRemainder.dx -= sx * step
        scrollRemainder.dy -= sy * step
        let cap = max(0, configuration.maxScrollStepsPerUpdate)
        let stepsX = Int(max(-CGFloat(cap), min(CGFloat(cap), sx)))
        let stepsY = Int(max(-CGFloat(cap), min(CGFloat(cap), sy)))
        guard stepsX != 0 || stepsY != 0 else { return [] }
        let p = cursorPixel
        return [.sendScroll(x: p.x, y: p.y, deltaX: stepsX, deltaY: stepsY, buttons: buttons)]
    }

    /// Two-finger drag ended; the sub-step remainder is discarded.
    public mutating func scrollEnded() -> [PointerAction] {
        guard mode == .scrolling else { return [] }
        mode = .idle
        scrollRemainder = .zero
        return []
    }

    // MARK: - Pinch

    /// Pinch began at `centroid` (view points).
    public mutating func pinchBegan(centroid: CGPoint) -> [PointerAction] {
        guard finite(centroid) else { return [] }
        let out = finishCurrentMode()
        mode = .pinching
        lastPinchScale = 1
        lastPinchCentroid = centroid
        return out
    }

    /// Pinch changed. `scale` is the recognizer's cumulative scale since the pinch began (1 = unchanged).
    public mutating func pinchChanged(scale: CGFloat, centroid: CGPoint) -> [PointerAction] {
        guard mode == .pinching, scale.isFinite, scale > 0, lastPinchScale > 0, finite(centroid) else { return [] }
        let before = viewport
        viewport.zoom(by: scale / lastPinchScale, around: centroid)
        viewport.pan(by: CGVector(dx: centroid.x - lastPinchCentroid.x, dy: centroid.y - lastPinchCentroid.y))
        lastPinchScale = scale
        lastPinchCentroid = centroid
        return viewport != before ? [.viewportChanged(viewport)] : []
    }

    /// Pinch ended.
    public mutating func pinchEnded() -> [PointerAction] {
        guard mode == .pinching else { return [] }
        mode = .idle
        return []
    }

    // MARK: - Toolbar / discrete commands

    /// Left click (press + release) at the cursor.
    public mutating func click() -> [PointerAction] {
        guard viewport.isValid else { return [] }
        let out = finishCurrentMode()
        return out + clickSequence(.left, count: 1) + [.feedback(.click)]
    }

    /// Two left clicks back to back at the cursor.
    public mutating func doubleClick() -> [PointerAction] {
        guard viewport.isValid else { return [] }
        let out = finishCurrentMode()
        return out + clickSequence(.left, count: 2) + [.feedback(.doubleClick)]
    }

    /// Right click at the cursor (toolbar button and two-finger tap).
    public mutating func rightClick() -> [PointerAction] {
        guard viewport.isValid else { return [] }
        let out = finishCurrentMode()
        return out + clickSequence(.right, count: 1) + [.feedback(.rightClick)]
    }

    /// Two-finger tap: right click at the cursor (not at the tap location).
    public mutating func twoFingerTap() -> [PointerAction] { rightClick() }

    /// Abort whatever is in progress (gesture cancelled, app backgrounded, disconnect):
    /// releases held buttons and hides the loupe.
    public mutating func cancel() -> [PointerAction] { finishCurrentMode() }

    // MARK: - Internals

    /// Ends the current mode cleanly. Releases buttons with a pointer event if any are held.
    private mutating func finishCurrentMode() -> [PointerAction] {
        var out: [PointerAction] = []
        switch mode {
        case .aiming:
            out.append(.loupe(visible: false))
        case .dragging:
            out.append(.loupe(visible: false))
        case .idle, .scrolling, .pinching:
            break
        }
        let wasDragging = mode == .dragging
        mode = .idle
        scrollRemainder = .zero
        if !buttons.isEmpty {
            buttons = []
            out.append(sendPointerForced())
            if wasDragging { out.append(.feedback(.dragEnded)) }
        }
        return out
    }

    private mutating func followFinger(to viewPoint: CGPoint) -> [PointerAction] {
        let s = viewport.scale
        guard s > 0 else { return [] }
        let g = configuration.gain.isFinite ? configuration.gain : 0
        let d = CGPoint(x: (viewPoint.x - lastFinger.x) / s * g, y: (viewPoint.y - lastFinger.y) / s * g)
        lastFinger = viewPoint
        return moveCursor(to: CGPoint(x: cursor.x + d.x, y: cursor.y + d.y))
    }

    /// Moves the (continuous) cursor, clamps it, follows it with the viewport and emits a pointer
    /// event if the integer pixel or the buttons changed since the last event.
    private mutating func moveCursor(to p: CGPoint) -> [PointerAction] {
        guard finite(p) else { return [] }
        cursor = clamped(p)
        var out: [PointerAction] = []
        if viewport.ensureVisible(remotePoint: cursor, margin: configuration.followMargin) {
            out.append(.viewportChanged(viewport))
        }
        let px = pixel(cursor)
        if let last = lastSent, last.x == px.x, last.y == px.y, last.buttons == buttons {
            return out
        }
        out.insert(sendPointerForced(), at: 0)
        return out
    }

    private mutating func sendPointerForced() -> PointerAction {
        let px = pixel(cursor)
        lastSent = (px.x, px.y, buttons)
        return .sendPointer(x: px.x, y: px.y, buttons: buttons)
    }

    /// Press/release pairs at the cursor. Starts with a move if the cursor position was never sent.
    private mutating func clickSequence(_ button: PointerButtons, count: Int) -> [PointerAction] {
        var out: [PointerAction] = []
        let px = pixel(cursor)
        if lastSent == nil || lastSent!.x != px.x || lastSent!.y != px.y {
            out.append(sendPointerForced())
        }
        for _ in 0..<count {
            buttons = button
            out.append(sendPointerForced())
            buttons = []
            out.append(sendPointerForced())
        }
        return out
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        // RFB coordinates are u16; also keeps the Int conversion in `pixel` safe.
        let maxX = min(65535, max(0, viewport.remoteSize.width - 1))
        let maxY = min(65535, max(0, viewport.remoteSize.height - 1))
        let x = p.x.isFinite ? min(max(p.x, 0), maxX) : 0
        let y = p.y.isFinite ? min(max(p.y, 0), maxY) : 0
        return CGPoint(x: x, y: y)
    }

    private func pixel(_ p: CGPoint) -> (x: Int, y: Int) {
        // `clamped` guarantees finite values within [0, remote-1].
        (Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
    }

    private func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
}
