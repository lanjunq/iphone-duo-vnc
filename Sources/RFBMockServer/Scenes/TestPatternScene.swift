import Foundation
import RFBBase

/// A deterministic test image that exercises every encoder path:
/// - top-left quarter: smooth RGB gradient (Tight gradient filter / JPEG, ZRLE raw)
/// - top-right quarter: 8x4 grid of solid blocks (fills, solid tiles)
/// - bottom-left quarter: 24-bit pseudo-random noise (raw tiles, Tight copy/JPEG)
/// - bottom-right quarter, upper half: 2-colour checkerboard (mono palette, Hextile subrects)
/// - bottom-right quarter, lower half: 4- and 12-colour stripes (packed palette, palette RLE)
///
/// Input: a left-button press paints an 8x8 white square at the pointer; a key press paints a 16x16
/// square at the top-left corner in a colour derived from the keysym.
public final class TestPatternScene: MockScene {
    public init() {}

    public var cursor: RFBCursor { MockCursors.arrow(scale: 1) }
    private var lastButtons: RFBButtonMask = []

    static let blockColors: [MockColor] = [
        MockColor(255, 0, 0), MockColor(0, 255, 0), MockColor(0, 0, 255), MockColor(255, 255, 0),
        MockColor(255, 0, 255), MockColor(0, 255, 255), MockColor(255, 255, 255), MockColor(0, 0, 0),
        MockColor(128, 0, 0), MockColor(0, 128, 0), MockColor(0, 0, 128), MockColor(128, 128, 0),
        MockColor(128, 0, 128), MockColor(0, 128, 128), MockColor(192, 192, 192), MockColor(64, 64, 64),
    ]

    public func render(into fb: Framebuffer) {
        let (w, h) = fb.size
        guard w > 0, h > 0 else { return }
        let hw = w / 2, hh = h / 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 0x1234_5678
        for y in 0..<h {
            for x in 0..<w {
                var r = 0, g = 0, b = 0
                if y < hh && x < hw {
                    r = hw > 1 ? x * 255 / (hw - 1) : 0
                    g = hh > 1 ? y * 255 / (hh - 1) : 0
                    b = 96
                } else if y < hh {
                    let bx = (x - hw) * 8 / max(1, w - hw), by = y * 4 / max(1, hh)
                    let c = Self.blockColors[(by * 8 + bx) % Self.blockColors.count]
                    r = Int(c.r); g = Int(c.g); b = Int(c.b)
                } else if x < hw {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    r = Int((seed >> 24) & 0xff); g = Int((seed >> 16) & 0xff); b = Int((seed >> 8) & 0xff)
                } else if y < hh + (h - hh) / 2 {
                    let on = ((x - hw) / 8 + (y - hh) / 8) % 2 == 0
                    r = on ? 250 : 20; g = on ? 250 : 40; b = on ? 250 : 90
                } else if x < hw + (w - hw) / 2 {
                    let c = Self.blockColors[((x + y) / 6) % 4]
                    r = Int(c.r); g = Int(c.g); b = Int(c.b)
                } else {
                    let c = Self.blockColors[((x / 3) + (y / 5)) % 12]
                    r = Int(c.r); g = Int(c.g); b = Int(c.b)
                }
                let i = (y * w + x) * 4
                px[i] = UInt8(b); px[i + 1] = UInt8(g); px[i + 2] = UInt8(r); px[i + 3] = 255
            }
        }
        try? fb.writeBGRX(RFBRect(x: 0, y: 0, width: w, height: h), px)
    }

    public func pointerEvent(x: Int, y: Int, buttons: RFBButtonMask, framebuffer fb: Framebuffer) -> [RFBRect] {
        defer { lastButtons = buttons }
        guard buttons.contains(.left), !lastButtons.contains(.left) else { return [] }
        let bounds = RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)
        let r = RFBRect(x: x, y: y, width: 8, height: 8).intersection(bounds)
        if r.isEmpty { return [] }
        try? fb.fill(r, blue: 255, green: 255, red: 255)
        return [r]
    }

    public func keyEvent(keysym: UInt32, down: Bool, framebuffer fb: Framebuffer) -> [RFBRect] {
        guard down else { return [] }
        let bounds = RFBRect(x: 0, y: 0, width: fb.width, height: fb.height)
        let r = RFBRect(x: 0, y: 0, width: 16, height: 16).intersection(bounds)
        if r.isEmpty { return [] }
        let h = keysym &* 2_654_435_761
        try? fb.fill(r, blue: UInt8(h & 0xff), green: UInt8((h >> 8) & 0xff), red: UInt8((h >> 16) & 0xff))
        return [r]
    }
}
