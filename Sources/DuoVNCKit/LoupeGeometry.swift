import Foundation
import CoreGraphics

/// Geometry of the magnifier shown while aiming.
public enum LoupeGeometry {
    /// Side (remote pixels, whole and even) of the square region the loupe shows: the loupe magnifies
    /// the current view by `magnification`. Clamped to `minSide...maxSide`.
    public static func sourceSide(loupeSize: CGFloat, viewportScale: CGFloat, magnification: CGFloat = 4,
                                  minSide: CGFloat = 16, maxSide: CGFloat = 512) -> CGFloat {
        guard loupeSize.isFinite, loupeSize > 0, viewportScale.isFinite, viewportScale > 0,
              magnification.isFinite, magnification > 0 else { return minSide }
        let raw = loupeSize / (viewportScale * magnification)
        let even = (raw / 2).rounded() * 2
        return min(max(even, minSide), maxSide)
    }

    /// The remote-pixel rectangle around `cursorPixel` (integral), moved inside the remote bounds when it
    /// would cross an edge (and shrunk if the remote screen is smaller than `side`).
    public static func sourceRect(cursorPixel: (x: Int, y: Int), remoteSize: CGSize, side: CGFloat) -> CGRect {
        let rw = remoteSize.width.isFinite ? max(0, remoteSize.width.rounded(.down)) : 0
        let rh = remoteSize.height.isFinite ? max(0, remoteSize.height.rounded(.down)) : 0
        guard rw > 0, rh > 0, side.isFinite, side > 0 else { return .zero }
        let s = side.rounded(.down)
        let w = min(s, rw), h = min(s, rh)
        var x = (CGFloat(cursorPixel.x) + 0.5 - w / 2).rounded(.down)
        var y = (CGFloat(cursorPixel.y) + 0.5 - h / 2).rounded(.down)
        x = min(max(0, x), rw - w)
        y = min(max(0, y), rh - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Where the cursor pixel's center appears inside a loupe of `loupeSize` points showing `source`.
    public static func crosshairPoint(cursorPixel: (x: Int, y: Int), source: CGRect, loupeSize: CGSize) -> CGPoint {
        guard source.width > 0, source.height > 0 else { return CGPoint(x: loupeSize.width / 2, y: loupeSize.height / 2) }
        let cx = (CGFloat(cursorPixel.x) + 0.5 - source.minX) / source.width * loupeSize.width
        let cy = (CGFloat(cursorPixel.y) + 0.5 - source.minY) / source.height * loupeSize.height
        return CGPoint(x: cx, y: cy)
    }

    /// Loupe frame inside `bounds` (the desktop view), away from the cursor (and so from the finger):
    /// a top corner on the opposite horizontal half, or a bottom corner if the cursor is near the top.
    public static func frame(cursorView: CGPoint, bounds: CGRect, size: CGFloat, margin: CGFloat = 12) -> CGRect {
        let b = bounds.standardized
        let s = max(0, min(size, b.width - 2 * margin, b.height - 2 * margin))
        let left = b.minX + margin
        let right = b.maxX - margin - s
        let top = b.minY + margin
        let bottom = b.maxY - margin - s
        let x = cursorView.x > b.midX ? left : right
        // Use a bottom corner when the cursor is inside the top band where the loupe would sit.
        let y = (cursorView.y < top + s + margin) ? bottom : top
        return CGRect(x: x, y: y, width: s, height: s)
    }
}
