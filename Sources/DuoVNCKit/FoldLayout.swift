import Foundation
import CoreGraphics

public extension LayoutEngine {
    /// Layout that also respects division regions (the iPhone Duo fold while the device is partly folded).
    ///
    /// - A horizontal division (wider than tall, "laptop" posture) that crosses the usable area: the
    ///   desktop takes everything above it and the toolbar everything below it (bottom axis), as long as
    ///   the part below is at least `minimumToolbarThickness` tall and the part above is not empty.
    /// - A vertical division ("book" posture): the desktop takes the larger side (left on a tie), the
    ///   toolbar the other side (side axis), as long as that side is at least `minimumToolbarThickness` wide.
    /// - Otherwise (no active division, or one too close to an edge): the normal `layout(_:)`, with the
    ///   divisions added to the obstructions so toolbar buttons avoid them.
    /// The division itself is left empty.
    static func layout(_ input: Input, divisions: [CGRect]) -> Output {
        let usable = usableRect(input)
        let minT = minimumToolbarThickness
        let aspect = (input.remoteAspectRatio.isFinite && input.remoteAspectRatio > 0) ? input.remoteAspectRatio : 16.0 / 9.0
        let valid = divisions.compactMap { r -> CGRect? in
            let s = r.standardized
            guard s.origin.x.isFinite, s.origin.y.isFinite, s.width.isFinite, s.height.isFinite else { return nil }
            let i = s.intersection(usable)
            return (i.isNull || (i.width <= 0 && i.height <= 0)) ? nil : i
        }
        func keepOut(_ toolbar: CGRect) -> [CGRect] {
            input.obstructedRects.compactMap { r -> CGRect? in
                let s = r.standardized
                guard s.origin.x.isFinite, s.origin.y.isFinite, s.width.isFinite, s.height.isFinite else { return nil }
                let i = s.intersection(toolbar)
                return (i.isNull || i.isEmpty) ? nil : i
            }
        }
        if let d = valid.first {
            if d.width >= d.height {
                // Laptop posture.
                let top = CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: max(0, d.minY - usable.minY))
                let bottom = CGRect(x: usable.minX, y: d.maxY, width: usable.width, height: max(0, usable.maxY - d.maxY))
                if bottom.height >= minT && top.height > 0 {
                    return Output(desktopFrame: top, toolbarFrame: bottom, axis: .bottom,
                                  toolbarKeepOutRects: keepOut(bottom), fittedContentSize: aspectFit(aspect, in: top.size))
                }
            } else {
                // Book posture.
                let left = CGRect(x: usable.minX, y: usable.minY, width: max(0, d.minX - usable.minX), height: usable.height)
                let right = CGRect(x: d.maxX, y: usable.minY, width: max(0, usable.maxX - d.maxX), height: usable.height)
                let leftArea = aspectFit(aspect, in: left.size)
                let rightArea = aspectFit(aspect, in: right.size)
                let desktopIsLeft = leftArea.width * leftArea.height >= rightArea.width * rightArea.height
                let desktop = desktopIsLeft ? left : right
                let toolbar = desktopIsLeft ? right : left
                if toolbar.width >= minT && desktop.width > 0 {
                    return Output(desktopFrame: desktop, toolbarFrame: toolbar, axis: .side,
                                  toolbarKeepOutRects: keepOut(toolbar),
                                  fittedContentSize: aspectFit(aspect, in: desktop.size))
                }
            }
        }
        var plain = input
        plain.obstructedRects += valid
        return layout(plain)
    }
}
