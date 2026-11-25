import Foundation
import RFBBase

/// A fake macOS desktop for the app's demo mode and for judging tap accuracy and typing by eye.
///
/// Layout is designed in points for a 1920x1080-point desktop and drawn at `pointScale` pixels per point
/// (2 for the default 3840x2160, like a HiDPI Mac). Contents:
/// - a menu bar (24 pt) whose items are click targets, with a HITS / MISSES counter on the right;
/// - a "Click targets" window: traffic lights (12 pt discs) and rows of buttons of real macOS sizes
///   (8x8, 12x12, 48x12 mini, 60x16 small, 80x22 push, 14x14 checkbox, 100x28 large);
/// - a "Status" window: hits, misses, last click position, offset from the hit target's centre in pixels,
///   pointer position, buttons, right clicks, wheel counts, and a RESET button;
/// - a "Keyboard" window: large text showing every character received via KeyEvent (Return = new line,
///   BackSpace deletes, Escape clears), held modifiers, the last key events as hex keysyms, and the last
///   clipboard text received;
/// - a dock with 9 icons (56 pt) that are also targets.
///
/// Every left-button press counts as a hit (the target toggles green and gets a blue outline) or a miss.
/// The last 16 presses stay marked with crosshairs: green = hit, red = miss, blue = right click.
public final class DemoDesktopScene: MockScene {
    // MARK: Public state (for tests and the app)

    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var rightClicks = 0
    /// Wheel presses: up, down, left, right.
    public private(set) var wheel = [0, 0, 0, 0]
    /// Everything typed so far (after BackSpace/Escape editing).
    public private(set) var typedText = ""
    /// Name of the target hit by the last left press, or nil for a miss / no press yet.
    public private(set) var lastHitName: String?
    /// Pixels per point.
    public let pointScale: Int

    public var cursor: RFBCursor { MockCursors.arrow(scale: pointScale) }

    // MARK: Model

    enum Kind { case menu, light(MockColor), button, checkbox, dock(MockColor), reset }

    struct Target {
        let name: String
        let rect: RFBRect      // pixels
        let kind: Kind
        let label: String
        var on = false
    }

    struct Marker { let x: Int; let y: Int; let color: MockColor }

    private var width: Int
    private var height: Int
    private(set) var targets: [Target] = []
    private var markers: [Marker] = []
    private var lastHitIndex: Int?
    private var lastClick: (x: Int, y: Int)?
    private var lastOffset: (dx: Double, dy: Double)?
    private var pointer = (x: 0, y: 0)
    private var buttons: RFBButtonMask = []
    private var keyLog: [String] = []
    private var modifiers = Set<String>()
    private var clipText = ""

    // MARK: Colours

    static let desktop = MockColor(40, 90, 150)
    static let menuBar = MockColor(236, 236, 236)
    static let windowBody = MockColor(246, 246, 246)
    static let titleBar = MockColor(226, 226, 226)
    static let border = MockColor(150, 150, 150)
    static let text = MockColor(30, 30, 30)
    static let buttonOff = MockColor(255, 255, 255)
    static let buttonOn = MockColor(40, 190, 80)
    static let highlight = MockColor(0, 122, 255)
    static let hitColor = MockColor(0, 200, 60)
    static let missColor = MockColor(235, 30, 30)
    static let rightColor = MockColor(30, 110, 255)
    static let modOn = MockColor(255, 150, 0)

    // MARK: Layout (points)

    private let clickWindow = (x: 40, y: 60, w: 980, h: 700)
    private let statusWindow = (x: 1060, y: 60, w: 820, h: 330)
    private let keyWindow = (x: 1060, y: 420, w: 820, h: 430)
    private let charsPerLine = 32
    private let textLines = 4

    /// - Parameters:
    ///   - width, height: framebuffer size in pixels.
    ///   - pointScale: pixels per point; default `max(1, min(width / 1920, height / 1080))`.
    public init(width: Int = 3840, height: Int = 2160, pointScale: Int? = nil) {
        self.width = width
        self.height = height
        self.pointScale = max(1, pointScale ?? min(width / 1920, height / 1080))
        buildTargets()
    }

    private func R(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> RFBRect {
        RFBRect(x: x * pointScale, y: y * pointScale, width: w * pointScale, height: h * pointScale)
    }

    private var logicalWidth: Int { width / pointScale }
    private var logicalHeight: Int { height / pointScale }

    private func buildTargets() {
        targets = []
        // Menu bar items.
        var mx = 10
        for (i, item) in ["DuoVNC", "File", "Edit", "View", "Window", "Help"].enumerated() {
            let w = Canvas.textWidth(item, scale: 2) + 20
            targets.append(Target(name: "menu:\(item)", rect: R(mx, 0, w, 24), kind: .menu, label: item))
            mx += w
            _ = i
        }
        // Traffic lights.
        let lights = [("close", MockColor(255, 95, 87)), ("minimize", MockColor(254, 188, 46)), ("zoom", MockColor(40, 200, 64))]
        for (i, l) in lights.enumerated() {
            targets.append(Target(name: "light:\(l.0)", rect: R(clickWindow.x + 10 + 20 * i, clickWindow.y + 8, 12, 12),
                                  kind: .light(l.1), label: ""))
        }
        // Button rows: (label, width, height, count, kind)
        let rows: [(String, Int, Int, Int, Kind)] = [
            ("8x8 pt", 8, 8, 12, .button),
            ("12x12 pt", 12, 12, 12, .button),
            ("mini 48x12", 48, 12, 10, .button),
            ("small 60x16", 60, 16, 9, .button),
            ("push 80x22", 80, 22, 7, .button),
            ("check 14x14", 14, 14, 12, .checkbox),
            ("big 100x28", 100, 28, 6, .button),
        ]
        let bx = clickWindow.x + 20 + 160
        var by = clickWindow.y + 28 + 30
        for (r, row) in rows.enumerated() {
            let gap = row.1 <= 14 ? 16 : 12
            for i in 0..<row.3 {
                let name = "row\(r + 1):\(i + 1)"
                targets.append(Target(name: name, rect: R(bx + i * (row.1 + gap), by + (28 - row.2) / 2, row.1, row.2),
                                      kind: row.4, label: "\(i + 1)"))
            }
            by += 64
        }
        // Reset button.
        targets.append(Target(name: "reset", rect: R(statusWindow.x + statusWindow.w - 130, statusWindow.y + statusWindow.h - 48, 110, 32),
                              kind: .reset, label: "RESET"))
        // Dock.
        let dockColors = [MockColor(30, 144, 255), MockColor(52, 199, 89), MockColor(255, 149, 0), MockColor(255, 59, 48),
                          MockColor(175, 82, 222), MockColor(90, 200, 250), MockColor(255, 204, 0), MockColor(142, 142, 147),
                          MockColor(255, 45, 85)]
        let dockW = dockColors.count * 56 + (dockColors.count - 1) * 12 + 24
        let dx = (logicalWidth - dockW) / 2 + 12
        for (i, c) in dockColors.enumerated() {
            targets.append(Target(name: "dock:\(i + 1)", rect: R(dx + i * 68, logicalHeight - 74, 56, 56), kind: .dock(c), label: ""))
        }
        rowLabelsY = rows.enumerated().map { (i, r) in (r.0, clickWindow.y + 28 + 30 + i * 64) }
    }

    private var rowLabelsY: [(String, Int)] = []

    // MARK: Rendering

    public func render(into fb: Framebuffer) {
        let (w, h) = fb.size
        if w != width || h != height {
            width = w
            height = h
            let keep = targets
            buildTargets()
            for i in targets.indices where i < keep.count && keep[i].name == targets[i].name { targets[i].on = keep[i].on }
            markers.removeAll()
            lastHitIndex = nil
        }
        draw(Canvas(fb))
    }

    private func redraw(_ fb: Framebuffer, _ rects: [RFBRect]) -> [RFBRect] {
        let bounds = RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)
        var out = [RFBRect]()
        for r in rects {
            let c = r.intersection(bounds)
            if c.isEmpty { continue }
            draw(Canvas(fb, clip: c))
            out.append(c)
        }
        return out
    }

    private func draw(_ c: Canvas) {
        let P = pointScale
        c.fill(RFBRect(x: 0, y: 0, width: width, height: height), Self.desktop)
        drawMenuBar(c)
        // Hint text on the desktop.
        c.text("DUO VNC DEMO: aim, then click. Every press is a hit or a miss.", x: 40 * P, y: 790 * P, scale: 2 * P, MockColor(255, 255, 255))
        c.text("Crosshairs: green = hit, red = miss, blue = right click. 1 pt = \(P) px.", x: 40 * P, y: 816 * P, scale: 2 * P, MockColor(220, 230, 255))
        drawWindow(c, clickWindow, title: "Click targets")
        for (label, y) in rowLabelsY {
            c.text(label, x: (clickWindow.x + 20) * P, y: (y + 7) * P, scale: 2 * P, Self.text)
        }
        drawWindow(c, statusWindow, title: "Status")
        drawStatus(c)
        drawWindow(c, keyWindow, title: "Keyboard - type here")
        drawKeyboard(c)
        drawDock(c)
        for (i, t) in targets.enumerated() { drawTarget(c, t, lastHit: i == lastHitIndex) }
        for m in markers { drawMarker(c, m) }
    }

    private func drawMenuBar(_ c: Canvas) {
        let P = pointScale
        let bar = R(0, 0, logicalWidth, 24)
        guard c.visible(bar) else { return }
        c.fill(bar, Self.menuBar)
        c.fill(RFBRect(x: 0, y: bar.maxY - P, width: width, height: P), MockColor(200, 200, 200))
        let s = "HITS \(hits)  MISSES \(misses)"
        let tw = Canvas.textWidth(s, scale: 2 * P)
        c.text(s, x: width - tw - 16 * P, y: 5 * P, scale: 2 * P, Self.text)
    }

    private func drawWindow(_ c: Canvas, _ w: (x: Int, y: Int, w: Int, h: Int), title: String) {
        let P = pointScale
        let frame = R(w.x, w.y, w.w, w.h)
        guard c.visible(frame) else { return }
        c.fill(frame, Self.windowBody)
        c.fill(R(w.x, w.y, w.w, 28), Self.titleBar)
        c.frame(frame, P, Self.border)
        c.fill(RFBRect(x: frame.x, y: frame.y + 28 * P, width: frame.width, height: P), MockColor(200, 200, 200))
        let tw = Canvas.textWidth(title, scale: 2 * P)
        c.text(title, x: frame.x + (frame.width - tw) / 2, y: frame.y + 7 * P, scale: 2 * P, Self.text)
    }

    private func statusLines() -> [(String, Int, MockColor)] {
        var lines: [(String, Int, MockColor)] = []
        lines.append(("HITS \(hits)   MISSES \(misses)", 3, Self.text))
        if let lc = lastClick {
            lines.append(("LAST \(lc.x),\(lc.y) px", 3, Self.text))
            if let name = lastHitName, let o = lastOffset {
                lines.append(("HIT \(name)  OFF \(String(format: "%+.1f,%+.1f", o.dx, o.dy))", 2, Self.hitColor))
            } else {
                lines.append(("MISS", 2, Self.missColor))
            }
        } else {
            lines.append(("LAST -", 3, Self.text))
            lines.append(("", 2, Self.text))
        }
        let b = (buttons.contains(.left) ? "L" : "-") + (buttons.contains(.middle) ? "M" : "-") + (buttons.contains(.right) ? "R" : "-")
        lines.append(("POINTER \(pointer.x),\(pointer.y) px  BTN \(b)", 2, Self.text))
        lines.append(("RIGHT \(rightClicks)  WHEEL U\(wheel[0]) D\(wheel[1]) L\(wheel[2]) R\(wheel[3])", 2, Self.text))
        return lines
    }

    /// Pixel rect of status line `i` (for partial redraws).
    private func statusLineRect(_ i: Int) -> RFBRect {
        R(statusWindow.x + 1, statusWindow.y + 40 + i * 34, statusWindow.w - 2, 32)
    }

    private func drawStatus(_ c: Canvas) {
        let P = pointScale
        for (i, l) in statusLines().enumerated() {
            let r = statusLineRect(i)
            guard c.visible(r) else { continue }
            c.text(l.0, x: (statusWindow.x + 20) * P, y: r.y + (32 - 7 * l.1) / 2 * P, scale: l.1 * P, l.2)
        }
    }

    private func textBoxRect() -> RFBRect { R(keyWindow.x + 16, keyWindow.y + 44, keyWindow.w - 32, textLines * 40 + 16) }

    /// The typed text wrapped into display lines (last `textLines` lines).
    func displayLines() -> [String] {
        var lines = [String]()
        for para in typedText.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = Substring(para)
            if s.isEmpty { lines.append(""); continue }
            while !s.isEmpty {
                lines.append(String(s.prefix(charsPerLine)))
                s = s.dropFirst(charsPerLine)
            }
        }
        if lines.isEmpty { lines = [""] }
        return Array(lines.suffix(textLines))
    }

    private func drawKeyboard(_ c: Canvas) {
        let P = pointScale
        let box = textBoxRect()
        if c.visible(box) {
            c.fill(box, MockColor(255, 255, 255))
            c.frame(box, P, Self.highlight)
            let lines = displayLines()
            for (i, l) in lines.enumerated() {
                c.text(l, x: box.x + 8 * P, y: box.y + (8 + i * 40) * P, scale: 4 * P, Self.text)
            }
            // Caret after the last character.
            let last = lines.last ?? ""
            let cx = box.x + (8 + last.unicodeScalars.count * 24) * P
            c.fill(RFBRect(x: cx, y: box.y + (8 + (lines.count - 1) * 40) * P, width: 2 * P, height: 30 * P), Self.highlight)
        }
        let y0 = keyWindow.y + 44 + textLines * 40 + 16 + 12
        c.text("LEN \(typedText.count)  (Return = new line, Esc = clear)", x: (keyWindow.x + 16) * P, y: y0 * P, scale: 2 * P, Self.text)
        let mods = ["SHIFT", "CTRL", "ALT", "CMD", "SUPER"]
        for (i, m) in mods.enumerated() {
            let r = R(keyWindow.x + 16 + i * 120, y0 + 26, 108, 30)
            guard c.visible(r) else { continue }
            let on = modifiers.contains(m)
            c.fill(r, on ? Self.modOn : MockColor(225, 225, 225))
            c.frame(r, P, Self.border)
            let tw = Canvas.textWidth(m, scale: 2 * P)
            c.text(m, x: r.x + (r.width - tw) / 2, y: r.y + 8 * P, scale: 2 * P, on ? MockColor(255, 255, 255) : Self.text)
        }
        c.text("KEYS " + keyLog.joined(separator: " "), x: (keyWindow.x + 16) * P, y: (y0 + 68) * P, scale: 2 * P, Self.text)
        let clip = clipText.count > 50 ? String(clipText.prefix(50)) + "..." : clipText
        c.text("CLIP " + clip.replacingOccurrences(of: "\n", with: " "), x: (keyWindow.x + 16) * P, y: (y0 + 92) * P, scale: 2 * P, Self.text)
    }

    private func keyboardDirtyRect() -> RFBRect { R(keyWindow.x + 1, keyWindow.y + 29, keyWindow.w - 2, keyWindow.h - 30) }

    private func drawDock(_ c: Canvas) {
        let n = targets.filter { if case .dock = $0.kind { return true }; return false }.count
        let dockW = n * 56 + (n - 1) * 12 + 24
        let r = R((logicalWidth - dockW) / 2, logicalHeight - 84, dockW, 76)
        guard c.visible(r) else { return }
        c.fill(r, MockColor(225, 228, 235))
        c.frame(r, pointScale, MockColor(170, 175, 185))
    }

    private func drawTarget(_ c: Canvas, _ t: Target, lastHit: Bool) {
        let P = pointScale
        let outline = RFBRect(x: t.rect.x - 4 * P, y: t.rect.y - 4 * P, width: t.rect.width + 8 * P, height: t.rect.height + 8 * P)
        guard c.visible(outline) else { return }
        switch t.kind {
        case .menu:
            c.fill(t.rect, t.on ? Self.highlight : Self.menuBar)
            let tw = Canvas.textWidth(t.label, scale: 2 * P)
            c.text(t.label, x: t.rect.x + (t.rect.width - tw) / 2, y: t.rect.y + 5 * P, scale: 2 * P,
                   t.on ? MockColor(255, 255, 255) : Self.text)
        case .light(let col):
            c.disc(t.rect, t.on ? MockColor(60, 60, 60) : col)
        case .button, .reset:
            let isReset: Bool = { if case .reset = t.kind { return true }; return false }()
            c.fill(t.rect, t.on ? Self.buttonOn : (isReset ? MockColor(255, 230, 230) : Self.buttonOff))
            c.frame(t.rect, P, t.on ? MockColor(20, 120, 50) : Self.border)
            // Label only where it fits (cell 6x8 pt at text scale 1).
            let ts = t.rect.height >= 28 * P ? 2 : 1
            let tw = Canvas.textWidth(t.label, scale: ts * P)
            if tw + 4 * P <= t.rect.width && 7 * ts * P + 4 * P <= t.rect.height {
                c.text(t.label, x: t.rect.x + (t.rect.width - tw) / 2, y: t.rect.y + (t.rect.height - 7 * ts * P) / 2, scale: ts * P,
                       t.on ? MockColor(255, 255, 255) : Self.text)
            }
        case .checkbox:
            c.fill(t.rect, Self.buttonOff)
            c.frame(t.rect, P, Self.border)
            if t.on {
                let inset = RFBRect(x: t.rect.x + 3 * P, y: t.rect.y + 3 * P, width: t.rect.width - 6 * P, height: t.rect.height - 6 * P)
                c.fill(inset, Self.buttonOn)
            }
        case .dock(let col):
            c.fill(t.rect, t.on ? MockColor(40, 40, 40) : col)
            if t.on { c.frame(t.rect, 3 * P, col) }
        }
        if lastHit { c.frame(outline, 2 * P, Self.highlight) }
    }

    private func markerRect(_ m: Marker) -> RFBRect {
        let a = 8 * pointScale + 1
        return RFBRect(x: m.x - a, y: m.y - a, width: 2 * a + 1, height: 2 * a + 1)
    }

    private func drawMarker(_ c: Canvas, _ m: Marker) {
        let P = pointScale
        let a = 8 * P
        guard c.visible(markerRect(m)) else { return }
        // Dark halo, then the coloured cross; the exact click pixel is left as a 1-pixel gap at the centre.
        let black = MockColor(0, 0, 0)
        c.fill(RFBRect(x: m.x - a - 1, y: m.y - P / 2 - 1, width: 2 * a + 3, height: P + 2), black)
        c.fill(RFBRect(x: m.x - P / 2 - 1, y: m.y - a - 1, width: P + 2, height: 2 * a + 3), black)
        c.fill(RFBRect(x: m.x - a, y: m.y - P / 2, width: 2 * a + 1, height: P), m.color)
        c.fill(RFBRect(x: m.x - P / 2, y: m.y - a, width: P, height: 2 * a + 1), m.color)
        c.fill(RFBRect(x: m.x, y: m.y, width: 1, height: 1), MockColor(255, 255, 255))
    }

    // MARK: Input

    private func targetRegion(_ i: Int) -> RFBRect {
        let r = targets[i].rect, P = pointScale
        return RFBRect(x: r.x - 4 * P, y: r.y - 4 * P, width: r.width + 8 * P, height: r.height + 8 * P)
    }

    private func statusRegion() -> RFBRect { R(statusWindow.x + 1, statusWindow.y + 29, statusWindow.w - 2, statusWindow.h - 30) }

    private func addMarker(_ m: Marker, dirty: inout [RFBRect]) {
        markers.append(m)
        dirty.append(markerRect(m))
        if markers.count > 16 { dirty.append(markerRect(markers.removeFirst())) }
    }

    public func pointerEvent(x: Int, y: Int, buttons newButtons: RFBButtonMask, framebuffer fb: Framebuffer) -> [RFBRect] {
        let pressed = RFBButtonMask(rawValue: newButtons.rawValue & ~buttons.rawValue)
        let moved = (x, y) != pointer
        let buttonsChanged = newButtons != buttons
        pointer = (x, y)
        buttons = newButtons
        var dirty = [RFBRect]()
        if moved || buttonsChanged { dirty.append(statusLineRect(3)) }

        if pressed.contains(.left) {
            lastClick = (x, y)
            let old = lastHitIndex
            if let i = targets.firstIndex(where: { x >= $0.rect.x && x < $0.rect.maxX && y >= $0.rect.y && y < $0.rect.maxY }) {
                if case .reset = targets[i].kind {
                    reset()
                    return redraw(fb, [RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)])
                }
                hits += 1
                targets[i].on.toggle()
                lastHitIndex = i
                lastHitName = targets[i].name
                let r = targets[i].rect
                lastOffset = (Double(x) - (Double(r.x) + Double(r.width - 1) / 2), Double(y) - (Double(r.y) + Double(r.height - 1) / 2))
                dirty.append(targetRegion(i))
                addMarker(Marker(x: x, y: y, color: Self.hitColor), dirty: &dirty)
            } else {
                misses += 1
                lastHitIndex = nil
                lastHitName = nil
                lastOffset = nil
                addMarker(Marker(x: x, y: y, color: Self.missColor), dirty: &dirty)
            }
            if let old { dirty.append(targetRegion(old)) }
            dirty.append(statusRegion())
            dirty.append(R(logicalWidth / 2, 0, logicalWidth - logicalWidth / 2, 24))
        }
        if pressed.contains(.right) {
            rightClicks += 1
            addMarker(Marker(x: x, y: y, color: Self.rightColor), dirty: &dirty)
            dirty.append(statusLineRect(4))
        }
        let wheelBits: [RFBButtonMask] = [.wheelUp, .wheelDown, .wheelLeft, .wheelRight]
        for (k, b) in wheelBits.enumerated() where pressed.contains(b) {
            wheel[k] += 1
            dirty.append(statusLineRect(4))
        }
        return redraw(fb, dirty)
    }

    private func reset() {
        hits = 0; misses = 0; rightClicks = 0; wheel = [0, 0, 0, 0]
        typedText = ""; keyLog = []; clipText = ""
        lastHitName = nil; lastHitIndex = nil; lastClick = nil; lastOffset = nil
        markers = []
        for i in targets.indices { targets[i].on = false }
    }

    static func character(for keysym: UInt32) -> String? {
        switch keysym {
        case 0x20...0x7E, 0xA0...0xFF:
            return Unicode.Scalar(keysym).map { String(Character($0)) }
        case 0x0100_0000...0x0110_FFFF:
            return Unicode.Scalar(keysym - 0x0100_0000).map { String(Character($0)) }
        case 0xFFB0...0xFFB9:
            return String(keysym - 0xFFB0)                     // KP_0...KP_9
        case 0xFFAA: return "*"
        case 0xFFAB: return "+"
        case 0xFFAD: return "-"
        case 0xFFAE: return "."
        case 0xFFAF: return "/"
        case 0xFFBD: return "="
        default: return nil
        }
    }

    static let modifierNames: [UInt32: String] = [
        0xFFE1: "SHIFT", 0xFFE2: "SHIFT", 0xFFE3: "CTRL", 0xFFE4: "CTRL",
        // As macOS Screen Sharing reads them: Super and Alt = Command, Meta = Option.
        0xFFE9: "CMD", 0xFFEA: "CMD", 0xFFE7: "OPT", 0xFFE8: "OPT", 0xFFEB: "CMD", 0xFFEC: "CMD",
    ]

    public func keyEvent(keysym: UInt32, down: Bool, framebuffer fb: Framebuffer) -> [RFBRect] {
        keyLog.append(String(keysym, radix: 16) + (down ? "+" : "-"))
        if keyLog.count > 8 { keyLog.removeFirst(keyLog.count - 8) }
        if let m = Self.modifierNames[keysym] {
            if down { modifiers.insert(m) } else { modifiers.remove(m) }
        } else if down {
            switch keysym {
            case 0xFF08: if !typedText.isEmpty { typedText.removeLast() }       // BackSpace
            case 0xFF0D, 0xFF8D: typedText.append("\n")                           // Return, KP_Enter
            case 0xFF09: typedText.append(" ")                                     // Tab
            case 0xFF1B: typedText = ""                                            // Escape
            default:
                if let s = Self.character(for: keysym) { typedText.append(s) }
            }
            if typedText.count > 4000 { typedText = String(typedText.suffix(2000)) }
        }
        return redraw(fb, [keyboardDirtyRect()])
    }

    public func cutText(_ text: String, framebuffer fb: Framebuffer) -> [RFBRect] {
        clipText = text
        return redraw(fb, [keyboardDirtyRect()])
    }
}
