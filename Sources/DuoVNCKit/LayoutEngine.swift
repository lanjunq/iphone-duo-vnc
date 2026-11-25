import Foundation
import CoreGraphics

/// Edge insets without UIKit (convert from `UIEdgeInsets` field by field).
public struct LayoutInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat
    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
    public static let zero = LayoutInsets()
}

/// Session screen layout: the desktop area plus a toolbar that takes all leftover space.
public enum LayoutEngine {
    /// Minimum toolbar thickness in points.
    public static let minimumToolbarThickness: CGFloat = 56

    public enum ToolbarAxis: Equatable, Sendable {
        /// Horizontal bar below the desktop (leftover space is vertical).
        case bottom
        /// Vertical bar beside the desktop, on the trailing (right) side (leftover space is horizontal).
        case side
    }

    public struct Input: Equatable, Sendable {
        /// The container's bounds (points).
        public var bounds: CGRect
        public var safeAreaInsets: LayoutInsets
        /// Areas that cannot show content (fold, camera), in container coordinates.
        public var obstructedRects: [CGRect]
        /// Remote width / height (e.g. 16/9). Non-finite or <= 0 is treated as 16/9.
        public var remoteAspectRatio: CGFloat
        /// Height of the on-screen keyboard overlapping the container's bottom edge (0 = hidden).
        public var keyboardHeight: CGFloat

        public init(bounds: CGRect, safeAreaInsets: LayoutInsets = .zero, obstructedRects: [CGRect] = [],
                    remoteAspectRatio: CGFloat, keyboardHeight: CGFloat = 0) {
            self.bounds = bounds
            self.safeAreaInsets = safeAreaInsets
            self.obstructedRects = obstructedRects
            self.remoteAspectRatio = remoteAspectRatio
            self.keyboardHeight = keyboardHeight
        }
    }

    public struct Output: Equatable, Sendable {
        /// Where the remote desktop view goes. The viewport fits the remote screen into it.
        public var desktopFrame: CGRect
        public var toolbarFrame: CGRect
        public var axis: ToolbarAxis
        /// Parts of the toolbar that controls must avoid (obstructions crossing it), in container coordinates.
        public var toolbarKeepOutRects: [CGRect]
        /// Size the remote screen occupies inside `desktopFrame` when fitted (for diagnostics/tests).
        public var fittedContentSize: CGSize
    }

    /// Computes the layout.
    ///
    /// Rules: the usable area is the bounds minus the safe area, with the bottom raised to the top of
    /// the keyboard. For each axis the remote screen is aspect-fitted into the usable area minus a
    /// minimum-thickness toolbar; the axis that gives the larger fitted desktop wins (ties → bottom).
    /// The desktop frame is exactly as large as the fitted content along the toolbar axis (rounded
    /// down to whole points), so the toolbar absorbs all leftover space — no black bars on that axis.
    public static func layout(_ input: Input) -> Output {
        let usable = usableRect(input)
        let aspect = (input.remoteAspectRatio.isFinite && input.remoteAspectRatio > 0) ? input.remoteAspectRatio : 16.0 / 9.0
        let minT = minimumToolbarThickness

        // Candidate: bottom bar.
        let bAvailH = max(0, usable.height - minT)
        let bContent = aspectFit(aspect, in: CGSize(width: usable.width, height: bAvailH))
        // Candidate: side bar.
        let sAvailW = max(0, usable.width - minT)
        let sContent = aspectFit(aspect, in: CGSize(width: sAvailW, height: usable.height))

        let bArea = bContent.width * bContent.height
        let sArea = sContent.width * sContent.height
        let axis: ToolbarAxis = (sArea > bArea + 0.5) ? .side : .bottom

        var desktop: CGRect
        var toolbar: CGRect
        let content: CGSize
        switch axis {
        case .bottom:
            content = bContent
            let h = floor(bContent.height)
            desktop = CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: h)
            toolbar = CGRect(x: usable.minX, y: usable.minY + h, width: usable.width, height: max(0, usable.height - h))
        case .side:
            content = sContent
            let w = floor(sContent.width)
            desktop = CGRect(x: usable.minX, y: usable.minY, width: w, height: usable.height)
            toolbar = CGRect(x: usable.minX + w, y: usable.minY, width: max(0, usable.width - w), height: usable.height)
        }
        desktop = desktop.standardized
        toolbar = toolbar.standardized
        let keepOut = input.obstructedRects.compactMap { r -> CGRect? in
            guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
            let i = r.standardized.intersection(toolbar)
            return (i.isNull || i.isEmpty) ? nil : i
        }
        return Output(desktopFrame: desktop, toolbarFrame: toolbar, axis: axis,
                      toolbarKeepOutRects: keepOut, fittedContentSize: content)
    }

    static func usableRect(_ input: Input) -> CGRect {
        let b = input.bounds.standardized
        guard b.origin.x.isFinite, b.origin.y.isFinite, b.width.isFinite, b.height.isFinite else { return .zero }
        func f(_ v: CGFloat) -> CGFloat { v.isFinite ? max(0, v) : 0 }
        let i = input.safeAreaInsets
        let bottom = max(f(i.bottom), f(input.keyboardHeight))
        let x = b.minX + f(i.left)
        let y = b.minY + f(i.top)
        let w = max(0, b.width - f(i.left) - f(i.right))
        let h = max(0, b.height - f(i.top) - bottom)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func aspectFit(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }
}
