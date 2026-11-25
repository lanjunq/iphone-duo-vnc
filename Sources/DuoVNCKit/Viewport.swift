import Foundation
import CoreGraphics

/// Maps the remote framebuffer (pixels) into the local desktop area (points) and back.
///
/// Model: `viewPoint = remotePoint * scale + offset`. `scale` is points per remote pixel, `offset` is
/// the view-space position of the remote origin. All mutating operations keep the invariants:
/// - `fitScale <= scale <= maxScale` (when both sizes are non-empty);
/// - on each axis, content smaller than the view is centered; content larger than the view always
///   covers the view (no empty gap at an edge).
///
/// A degenerate remote or view size (zero/negative/non-finite) yields `scale == 0`, `offset == .zero`
/// and conversions that return `.zero`; nothing traps.
public struct Viewport: Equatable, Sendable {
    /// Remote framebuffer size in pixels.
    public private(set) var remoteSize: CGSize
    /// Size of the local desktop area in points.
    public private(set) var viewSize: CGSize
    /// Points per remote pixel.
    public private(set) var scale: CGFloat
    /// View-space position (points) of the remote origin.
    public private(set) var offset: CGPoint
    /// Maximum zoom expressed as a multiple of `fitScale` (default 16).
    public var maxZoomRelativeToFit: CGFloat {
        didSet {
            if !maxZoomRelativeToFit.isFinite || maxZoomRelativeToFit < 1 { maxZoomRelativeToFit = 1 }
            clampAll()
        }
    }

    /// Creates a viewport that starts fitted.
    public init(remoteSize: CGSize, viewSize: CGSize, maxZoomRelativeToFit: CGFloat = 16) {
        self.remoteSize = Viewport.sanitize(remoteSize)
        self.viewSize = Viewport.sanitize(viewSize)
        self.scale = 0
        self.offset = .zero
        self.maxZoomRelativeToFit = (maxZoomRelativeToFit.isFinite && maxZoomRelativeToFit >= 1) ? maxZoomRelativeToFit : 1
        fit()
    }

    private static func sanitize(_ s: CGSize) -> CGSize {
        let w = s.width.isFinite ? max(0, s.width) : 0
        let h = s.height.isFinite ? max(0, s.height) : 0
        return CGSize(width: w, height: h)
    }

    /// True when both sizes are non-empty, i.e. conversions are meaningful.
    public var isValid: Bool {
        remoteSize.width > 0 && remoteSize.height > 0 && viewSize.width > 0 && viewSize.height > 0
    }

    /// The scale at which the whole remote screen fits the view (aspect-fit). 0 when invalid.
    public var fitScale: CGFloat {
        guard isValid else { return 0 }
        return min(viewSize.width / remoteSize.width, viewSize.height / remoteSize.height)
    }

    /// Largest allowed scale: `fitScale * maxZoomRelativeToFit`.
    public var maxScale: CGFloat { fitScale * maxZoomRelativeToFit }

    /// `scale / fitScale` (1 = fitted). 0 when invalid.
    public var zoomRelativeToFit: CGFloat {
        let f = fitScale
        return f > 0 ? scale / f : 0
    }

    /// True when the viewport shows the whole remote screen.
    public var isFitted: Bool { isValid && abs(scale - fitScale) <= fitScale * 1e-9 }

    /// The visible part of the remote screen, in remote pixels (clipped to the remote bounds).
    public var visibleRemoteRect: CGRect {
        guard isValid, scale > 0 else { return .zero }
        let r = CGRect(x: -offset.x / scale, y: -offset.y / scale,
                       width: viewSize.width / scale, height: viewSize.height / scale)
        return r.intersection(CGRect(origin: .zero, size: remoteSize))
    }

    /// The remote screen's frame in view coordinates.
    public var contentFrame: CGRect {
        CGRect(x: offset.x, y: offset.y, width: remoteSize.width * scale, height: remoteSize.height * scale)
    }

    // MARK: Conversions

    /// Continuous remote coordinate under a view point (not clamped to the remote bounds).
    public func remotePoint(forView p: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    /// View point of a continuous remote coordinate.
    public func viewPoint(forRemote p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    // MARK: Mutations

    /// Shows the whole remote screen, centered.
    public mutating func fit() {
        scale = fitScale
        offset = .zero
        clampOffset()
    }

    /// Changes the remote size (DesktopSize) and re-fits.
    public mutating func setRemoteSize(_ size: CGSize) {
        remoteSize = Viewport.sanitize(size)
        fit()
    }

    /// Changes the view size (rotation, fold, keyboard) while preserving the relative zoom and the
    /// remote point at the view center. A fitted viewport stays fitted.
    public mutating func setViewSize(_ size: CGSize) {
        let newSize = Viewport.sanitize(size)
        guard newSize != viewSize else { return }
        let wasFitted = isFitted || !isValid
        let relZoom = zoomRelativeToFit
        let center = remotePoint(forView: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        viewSize = newSize
        if wasFitted { fit(); return }
        scale = fitScale * relZoom
        clampScale()
        offset = CGPoint(x: viewSize.width / 2 - center.x * scale, y: viewSize.height / 2 - center.y * scale)
        clampOffset()
    }

    /// Multiplies the scale by `factor` (clamped to `fitScale...maxScale`), keeping the remote point
    /// under the view point `anchor` fixed where clamping allows. Non-finite or non-positive factors
    /// are ignored.
    public mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard isValid, factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
        setScale(scale * factor, around: anchor)
    }

    /// Sets an absolute zoom relative to fit (clamped), keeping the remote point under `anchor` fixed.
    public mutating func setZoomRelativeToFit(_ zoom: CGFloat, around anchor: CGPoint) {
        guard isValid, zoom.isFinite, zoom > 0 else { return }
        setScale(fitScale * zoom, around: anchor)
    }

    /// Centers the view on a remote point at the given relative zoom (clamped at the edges).
    public mutating func center(onRemote p: CGPoint, zoomRelativeToFit zoom: CGFloat) {
        guard isValid, zoom.isFinite, zoom > 0, p.x.isFinite, p.y.isFinite else { return }
        scale = fitScale * zoom
        clampScale()
        offset = CGPoint(x: viewSize.width / 2 - p.x * scale, y: viewSize.height / 2 - p.y * scale)
        clampOffset()
    }

    private mutating func setScale(_ newScale: CGFloat, around anchor: CGPoint) {
        let remoteAnchor = remotePoint(forView: anchor)
        scale = newScale
        clampScale()
        offset = CGPoint(x: anchor.x - remoteAnchor.x * scale, y: anchor.y - remoteAnchor.y * scale)
        clampOffset()
    }

    /// Moves the content by `delta` points (content follows the finger), clamped.
    public mutating func pan(by delta: CGVector) {
        guard isValid, delta.dx.isFinite, delta.dy.isFinite else { return }
        offset.x += delta.dx
        offset.y += delta.dy
        clampOffset()
    }

    /// Pans the minimum amount so that `remotePoint` lies at least `margin` points inside the view
    /// edges (if the view is too small for the margin, the point is centered on that axis).
    /// Returns true if the offset changed.
    @discardableResult
    public mutating func ensureVisible(remotePoint p: CGPoint, margin: CGFloat) -> Bool {
        guard isValid, p.x.isFinite, p.y.isFinite else { return false }
        let m = margin.isFinite ? max(0, margin) : 0
        let before = offset
        let v = viewPoint(forRemote: p)
        offset.x += Viewport.correction(v.x, extent: viewSize.width, margin: m)
        offset.y += Viewport.correction(v.y, extent: viewSize.height, margin: m)
        clampOffset()
        return offset != before
    }

    private static func correction(_ v: CGFloat, extent: CGFloat, margin: CGFloat) -> CGFloat {
        if margin * 2 >= extent { return extent / 2 - v }
        if v < margin { return margin - v }
        if v > extent - margin { return (extent - margin) - v }
        return 0
    }

    // MARK: Clamping

    private mutating func clampAll() {
        clampScale()
        clampOffset()
    }

    private mutating func clampScale() {
        guard isValid else { scale = 0; return }
        if !scale.isFinite { scale = fitScale }
        scale = min(max(scale, fitScale), maxScale)
    }

    private mutating func clampOffset() {
        guard isValid, scale > 0 else { offset = .zero; return }
        offset.x = Viewport.clampAxis(offset.x, content: remoteSize.width * scale, view: viewSize.width)
        offset.y = Viewport.clampAxis(offset.y, content: remoteSize.height * scale, view: viewSize.height)
    }

    private static func clampAxis(_ o: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
        if content <= view { return (view - content) / 2 }
        if !o.isFinite { return (view - content) / 2 }
        return min(0, max(view - content, o))
    }
}
