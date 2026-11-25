import Foundation
import RFBBase

/// Content of the mock desktop. Deterministic: the same sequence of calls yields the same pixels.
/// The server calls a scene from one task at a time (it serialises access), so scenes need no locking.
/// Input hooks update the framebuffer themselves and return the areas they changed.
public protocol MockScene: AnyObject {
    /// Draws the whole scene at the framebuffer's current size (also called after a desktop resize).
    func render(into framebuffer: Framebuffer)
    /// A PointerEvent arrived. Returns the changed areas.
    func pointerEvent(x: Int, y: Int, buttons: RFBButtonMask, framebuffer: Framebuffer) -> [RFBRect]
    /// A KeyEvent arrived. Returns the changed areas.
    func keyEvent(keysym: UInt32, down: Bool, framebuffer: Framebuffer) -> [RFBRect]
    /// ClientCutText arrived. Returns the changed areas.
    func cutText(_ text: String, framebuffer: Framebuffer) -> [RFBRect]
    /// The cursor image sent with the Cursor pseudo-encoding.
    var cursor: RFBCursor { get }
}

extension MockScene {
    public func pointerEvent(x: Int, y: Int, buttons: RFBButtonMask, framebuffer: Framebuffer) -> [RFBRect] { [] }
    public func keyEvent(keysym: UInt32, down: Bool, framebuffer: Framebuffer) -> [RFBRect] { [] }
    public func cutText(_ text: String, framebuffer: Framebuffer) -> [RFBRect] { [] }
    public var cursor: RFBCursor { MockCursors.arrow(scale: 1) }
}

/// Built-in cursor images.
public enum MockCursors {
    private static let arrowRows = [
        "B...........",
        "BB..........",
        "BWB.........",
        "BWWB........",
        "BWWWB.......",
        "BWWWWB......",
        "BWWWWWB.....",
        "BWWWWWWB....",
        "BWWWWWWWB...",
        "BWWWWWWWWB..",
        "BWWWWWWWWWB.",
        "BWWWWWWBBBBB",
        "BWWWBWWB....",
        "BWWBBWWB....",
        "BWB..BWWB...",
        "BB...BWWB...",
        "B.....BWWB..",
        "......BWWB..",
        ".......BB...",
    ]

    /// The classic black-outlined white arrow, 12x19 at scale 1, hotspot at the tip (0, 0).
    public static func arrow(scale: Int) -> RFBCursor {
        let s = max(1, scale)
        let w = 12 * s, h = arrowRows.count * s
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        for (ry, row) in arrowRows.enumerated() {
            for (rx, ch) in row.enumerated() where ch != "." {
                let v: UInt8 = ch == "W" ? 255 : 0
                for dy in 0..<s {
                    for dx in 0..<s {
                        let i = ((ry * s + dy) * w + rx * s + dx) * 4
                        bgra[i] = v; bgra[i + 1] = v; bgra[i + 2] = v; bgra[i + 3] = 255
                    }
                }
            }
        }
        return RFBCursor(width: w, height: h, hotspotX: 0, hotspotY: 0, bgra: Data(bgra))
    }
}

/// An RGB colour for scene drawing.
public struct MockColor: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// Clipped drawing helpers over a `Framebuffer`.
struct Canvas {
    let fb: Framebuffer
    let clip: RFBRect

    init(_ fb: Framebuffer, clip: RFBRect? = nil) {
        self.fb = fb
        let bounds = RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)
        self.clip = clip.map { $0.intersection(bounds) } ?? bounds
    }

    func visible(_ r: RFBRect) -> Bool { clip.intersects(r) }

    func fill(_ r: RFBRect, _ c: MockColor) {
        let i = r.intersection(clip)
        if i.isEmpty { return }
        try? fb.fill(i, blue: c.b, green: c.g, red: c.r)
    }

    func frame(_ r: RFBRect, _ t: Int, _ c: MockColor) {
        fill(RFBRect(x: r.x, y: r.y, width: r.width, height: t), c)
        fill(RFBRect(x: r.x, y: r.maxY - t, width: r.width, height: t), c)
        fill(RFBRect(x: r.x, y: r.y, width: t, height: r.height), c)
        fill(RFBRect(x: r.maxX - t, y: r.y, width: t, height: r.height), c)
    }

    /// Filled circle inscribed in `r` (row spans).
    func disc(_ r: RFBRect, _ c: MockColor) {
        if !visible(r) { return }
        let rad = Double(min(r.width, r.height)) / 2
        let cx = Double(r.x) + Double(r.width) / 2, cy = Double(r.y) + Double(r.height) / 2
        for row in 0..<r.height {
            let py = Double(r.y + row) + 0.5 - cy
            let d = rad * rad - py * py
            if d <= 0 { continue }
            let half = d.squareRoot()
            let x0 = Int((cx - half).rounded()), x1 = Int((cx + half).rounded())
            fill(RFBRect(x: x0, y: r.y + row, width: x1 - x0, height: 1), c)
        }
    }

    /// Draws ASCII text with the built-in 5x7 font; each font pixel is `scale` x `scale` pixels and each
    /// character cell is 6x8 font pixels. Non-ASCII characters draw as a box.
    func text(_ s: String, x: Int, y: Int, scale: Int, _ c: MockColor) {
        let cellW = 6 * scale
        let box = RFBRect(x: x, y: y, width: max(1, s.unicodeScalars.count) * cellW, height: 8 * scale)
        if !visible(box) { return }
        var cx = x
        for u in s.unicodeScalars {
            if visible(RFBRect(x: cx, y: y, width: cellW, height: 7 * scale)) {
                for col in 0..<5 {
                    let bits = BitmapFont.column(u, col)
                    if bits == 0 { continue }
                    var row = 0
                    while row < 7 {
                        if bits & (1 << row) != 0 {
                            var run = 1
                            while row + run < 7 && bits & (1 << (row + run)) != 0 { run += 1 }
                            fill(RFBRect(x: cx + col * scale, y: y + row * scale, width: scale, height: run * scale), c)
                            row += run
                        } else {
                            row += 1
                        }
                    }
                }
            }
            cx += cellW
        }
    }

    static func textWidth(_ s: String, scale: Int) -> Int { s.unicodeScalars.count * 6 * scale - scale }
}
