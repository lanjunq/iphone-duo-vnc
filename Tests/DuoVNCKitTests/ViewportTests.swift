import Foundation
import CoreGraphics
import Testing
@testable import DuoVNCKit

func approx(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
func approx(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool { approx(a.x, b.x, eps) && approx(a.y, b.y, eps) }

/// Asserts the viewport invariants: scale range and offset clamping/centering.
func checkInvariants(_ v: Viewport) {
    guard v.isValid else { return }
    #expect(v.scale >= v.fitScale - 1e-9)
    #expect(v.scale <= v.maxScale + 1e-9)
    let cw = v.remoteSize.width * v.scale, ch = v.remoteSize.height * v.scale
    if cw <= v.viewSize.width + 1e-9 {
        #expect(approx(v.offset.x, (v.viewSize.width - cw) / 2, 1e-6))
    } else {
        #expect(v.offset.x <= 1e-9 && v.offset.x >= v.viewSize.width - cw - 1e-9)
    }
    if ch <= v.viewSize.height + 1e-9 {
        #expect(approx(v.offset.y, (v.viewSize.height - ch) / 2, 1e-6))
    } else {
        #expect(v.offset.y <= 1e-9 && v.offset.y >= v.viewSize.height - ch - 1e-9)
    }
}

@Suite struct ViewportTests {
    let remote = CGSize(width: 3840, height: 2160)

    @Test func fitWideView() {
        let v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500))
        #expect(approx(v.fitScale, 500.0 / 2160.0))
        #expect(approx(v.scale, v.fitScale))
        #expect(v.isFitted)
        #expect(approx(v.zoomRelativeToFit, 1))
        // Content narrower than view → centered horizontally, flush vertically.
        let cw = 3840 * v.scale
        #expect(approx(v.offset.x, (890 - cw) / 2))
        #expect(approx(v.offset.y, 0))
        checkInvariants(v)
    }

    @Test func fitTallView() {
        let v = Viewport(remoteSize: remote, viewSize: CGSize(width: 400, height: 800))
        #expect(approx(v.fitScale, 400.0 / 3840.0))
        #expect(approx(v.offset.x, 0))
        #expect(approx(v.offset.y, (800 - 2160 * v.scale) / 2))
        checkInvariants(v)
    }

    @Test func conversionsRoundTrip() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        v.zoom(by: 3, around: CGPoint(x: 100, y: 200))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1234.5, y: 999.25), CGPoint(x: 3839, y: 2159)] {
            #expect(approx(v.remotePoint(forView: v.viewPoint(forRemote: p)), p, 1e-6))
        }
        // Remote origin maps to offset.
        #expect(approx(v.viewPoint(forRemote: .zero), v.offset))
    }

    @Test func zoomKeepsAnchorFixed() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500.625))
        let anchor = CGPoint(x: 400, y: 250)
        let r0 = v.remotePoint(forView: anchor)
        v.zoom(by: 2.5, around: anchor)
        #expect(approx(v.zoomRelativeToFit, 2.5))
        #expect(approx(v.remotePoint(forView: anchor), r0, 1e-6))
        checkInvariants(v)
        // Second zoom compounds.
        v.zoom(by: 2, around: anchor)
        #expect(approx(v.zoomRelativeToFit, 5))
        #expect(approx(v.remotePoint(forView: anchor), r0, 1e-6))
    }

    @Test func zoomClampsToRange() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        v.zoom(by: 0.1, around: CGPoint(x: 10, y: 10))
        #expect(v.isFitted)
        checkInvariants(v)
        v.zoom(by: 1000, around: CGPoint(x: 10, y: 10))
        #expect(approx(v.scale, v.maxScale))
        #expect(approx(v.zoomRelativeToFit, 16))
        checkInvariants(v)
    }

    @Test func zoomIgnoresGarbage() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        let before = v
        v.zoom(by: .nan, around: .zero)
        v.zoom(by: 0, around: .zero)
        v.zoom(by: -2, around: .zero)
        v.zoom(by: .infinity, around: .zero)
        v.zoom(by: 2, around: CGPoint(x: CGFloat.nan, y: 0))
        v.pan(by: CGVector(dx: CGFloat.nan, dy: 1))
        #expect(v == before)
    }

    @Test func zoomNearEdgeClampsOffset() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500.625))
        // Anchor at the very corner: no empty gap may appear.
        v.zoom(by: 4, around: CGPoint(x: 0, y: 0))
        #expect(approx(v.offset.x, 0) && approx(v.offset.y, 0))
        v.zoom(by: 1, around: CGPoint(x: 890, y: 500))
        checkInvariants(v)
    }

    @Test func panClamps() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500.625))
        v.pan(by: CGVector(dx: 100, dy: 100))
        #expect(v.isFitted)      // fitted content cannot move
        checkInvariants(v)
        v.setZoomRelativeToFit(4, around: CGPoint(x: 445, y: 250))
        let o = v.offset
        v.pan(by: CGVector(dx: -50, dy: 30))
        #expect(approx(v.offset.x, o.x - 50) && approx(v.offset.y, o.y + 30))
        v.pan(by: CGVector(dx: 1e7, dy: 1e7))
        #expect(approx(v.offset.x, 0) && approx(v.offset.y, 0))
        v.pan(by: CGVector(dx: -1e7, dy: -1e7))
        #expect(approx(v.offset.x, 890 - 3840 * v.scale))
        #expect(approx(v.offset.y, 500.625 - 2160 * v.scale))
        checkInvariants(v)
    }

    @Test func ensureVisibleMovesMinimally() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500.625))
        v.center(onRemote: CGPoint(x: 1920, y: 1080), zoomRelativeToFit: 4)
        checkInvariants(v)
        // Inside the margin: unchanged.
        let unchanged9840 = v.ensureVisible(remotePoint: CGPoint(x: 1920, y: 1080), margin: 40); #expect(unchanged9840 == false)
        // A point to the right, just out of view.
        let target = CGPoint(x: v.visibleRemoteRect.maxX + 10, y: 1080)
        let changed4258 = v.ensureVisible(remotePoint: target, margin: 40); #expect(changed4258)
        #expect(approx(v.viewPoint(forRemote: target).x, 890 - 40, 1e-6))
        // Above-left.
        let t2 = CGPoint(x: v.visibleRemoteRect.minX - 50, y: v.visibleRemoteRect.minY - 50)
        let changed1933 = v.ensureVisible(remotePoint: t2, margin: 40); #expect(changed1933)
        #expect(approx(v.viewPoint(forRemote: t2), CGPoint(x: 40, y: 40), 1e-6))
        checkInvariants(v)
    }

    @Test func ensureVisibleClampedAtContentEdge() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500.625))
        v.center(onRemote: CGPoint(x: 1920, y: 1080), zoomRelativeToFit: 4)
        // Point at the remote corner cannot be brought 40pt inside: offset clamps to content edge.
        v.ensureVisible(remotePoint: CGPoint(x: 3839, y: 2159), margin: 40)
        #expect(approx(v.offset.x, 890 - 3840 * v.scale))
        #expect(approx(v.offset.y, 500.625 - 2160 * v.scale))
        checkInvariants(v)
    }

    @Test func ensureVisibleHugeMarginCenters() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 500.625))
        v.center(onRemote: CGPoint(x: 1000, y: 1000), zoomRelativeToFit: 8)
        v.ensureVisible(remotePoint: CGPoint(x: 2000, y: 1200), margin: 10_000)
        #expect(approx(v.viewPoint(forRemote: CGPoint(x: 2000, y: 1200)), CGPoint(x: 445, y: 250.3125), 1e-6))
    }

    @Test func ensureVisibleWhenFittedIsNoop() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        let unchanged4232 = v.ensureVisible(remotePoint: CGPoint(x: 0, y: 0), margin: 40); #expect(unchanged4232 == false)
        #expect(v.isFitted)
    }

    @Test func setViewSizeKeepsFitAndZoom() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        v.setViewSize(CGSize(width: 678, height: 381))
        #expect(v.isFitted)
        checkInvariants(v)
        v.center(onRemote: CGPoint(x: 1000, y: 800), zoomRelativeToFit: 3)
        v.setViewSize(CGSize(width: 890, height: 500))
        #expect(approx(v.zoomRelativeToFit, 3))
        #expect(approx(v.remotePoint(forView: CGPoint(x: 445, y: 250)), CGPoint(x: 1000, y: 800), 1e-6))
        checkInvariants(v)
    }

    @Test func setRemoteSizeRefits() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        v.setZoomRelativeToFit(5, around: .zero)
        v.setRemoteSize(CGSize(width: 1920, height: 1080))
        #expect(v.isFitted)
        #expect(approx(v.fitScale, 890.0 / 1920.0))
        checkInvariants(v)
    }

    @Test func degenerateSizesDoNotTrap() {
        var v = Viewport(remoteSize: .zero, viewSize: CGSize(width: 890, height: 626))
        #expect(!v.isValid)
        #expect(v.scale == 0 && v.fitScale == 0 && v.zoomRelativeToFit == 0)
        #expect(v.remotePoint(forView: CGPoint(x: 5, y: 5)) == .zero)
        v.zoom(by: 2, around: .zero)
        v.pan(by: CGVector(dx: 3, dy: 3))
        let unchanged1707 = v.ensureVisible(remotePoint: .zero, margin: 10); #expect(unchanged1707 == false)
        #expect(v.offset == .zero)
        v.setRemoteSize(remote)
        #expect(v.isValid && v.isFitted)
        let w = Viewport(remoteSize: CGSize(width: CGFloat.nan, height: -5), viewSize: CGSize(width: CGFloat.infinity, height: 1))
        #expect(!w.isValid)
        var z = Viewport(remoteSize: remote, viewSize: .zero)
        z.setViewSize(CGSize(width: 890, height: 626))
        #expect(z.isFitted)
    }

    @Test func visibleRemoteRect() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 960, height: 540))
        #expect(approx(v.visibleRemoteRect.width, 3840) && approx(v.visibleRemoteRect.height, 2160))
        v.center(onRemote: CGPoint(x: 1920, y: 1080), zoomRelativeToFit: 4)
        let r = v.visibleRemoteRect
        #expect(approx(r.width, 960) && approx(r.height, 540))
        #expect(approx(r.midX, 1920) && approx(r.midY, 1080))
    }

    @Test func maxZoomSetterClamps() {
        var v = Viewport(remoteSize: remote, viewSize: CGSize(width: 890, height: 626))
        v.setZoomRelativeToFit(10, around: .zero)
        v.maxZoomRelativeToFit = 4
        #expect(approx(v.zoomRelativeToFit, 4))
        v.maxZoomRelativeToFit = 0.2
        #expect(v.maxZoomRelativeToFit == 1)
        #expect(v.isFitted)
        checkInvariants(v)
    }
}
