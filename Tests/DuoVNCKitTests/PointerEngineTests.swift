import Foundation
import CoreGraphics
import Testing
@testable import DuoVNCKit

/// Remote 3840x2160 in a 960x540 view → fitScale exactly 0.25 points per pixel, offset 0.
func makeEngine(_ config: PointerEngineConfiguration = PointerEngineConfiguration()) -> PointerEngine {
    PointerEngine(viewport: Viewport(remoteSize: CGSize(width: 3840, height: 2160), viewSize: CGSize(width: 960, height: 540)),
                  configuration: config)
}

func pointerEvents(_ actions: [PointerAction]) -> [PointerAction] {
    actions.filter { if case .sendPointer = $0 { return true } else { return false } }
}

func hasViewportChange(_ actions: [PointerAction]) -> Bool {
    actions.contains { if case .viewportChanged = $0 { return true } else { return false } }
}

func lastPointer(_ actions: [PointerAction]) -> (Int, Int, PointerButtons)? {
    for a in actions.reversed() { if case let .sendPointer(x, y, b) = a { return (x, y, b) } }
    return nil
}

@Suite struct PointerEngineBasics {
    @Test func initialState() {
        let e = makeEngine()
        #expect(e.mode == .idle)
        #expect(e.buttons.isEmpty)
        #expect(e.cursorPixel == (1920, 1080))
        #expect(e.viewport.isFitted)
        #expect(!e.tapClicksDirectly)
        #expect(approx(e.cursorViewPoint, CGPoint(x: 480.125, y: 270.125)))
    }

    @Test func buttonBitsMatchRFB() {
        #expect(PointerButtons.left.rawValue == 1)
        #expect(PointerButtons.middle.rawValue == 2)
        #expect(PointerButtons.right.rawValue == 4)
    }
}

@Suite struct AimTests {
    @Test func beginJumpsToFingerAndShowsLoupe() {
        var e = makeEngine()
        let a = e.aimBegan(at: CGPoint(x: 100, y: 50))
        #expect(a == [.loupe(visible: true), .sendPointer(x: 400, y: 200, buttons: [])])
        #expect(e.mode == .aiming)
    }

    @Test func followsWithGain() {
        var e = makeEngine()
        _ = e.aimBegan(at: CGPoint(x: 100, y: 50))
        // 10 pt → 40 px of remote space → ×0.5 = 20 px.
        #expect(e.aimChanged(to: CGPoint(x: 110, y: 50)) == [.sendPointer(x: 420, y: 200, buttons: [])])
        #expect(e.aimChanged(to: CGPoint(x: 110, y: 40)) == [.sendPointer(x: 420, y: 180, buttons: [])])
        // Moving back to the start point returns exactly to the start pixel (no drift).
        #expect(e.aimChanged(to: CGPoint(x: 100, y: 50)) == [.sendPointer(x: 400, y: 200, buttons: [])])
    }

    @Test func customGain() {
        var e = makeEngine(PointerEngineConfiguration(gain: 1.0))
        _ = e.aimBegan(at: CGPoint(x: 100, y: 50))
        #expect(e.aimChanged(to: CGPoint(x: 110, y: 55)) == [.sendPointer(x: 440, y: 220, buttons: [])])
    }

    @Test func gainIsInRemoteSpaceSoZoomSlowsTheCursor() {
        var e = makeEngine()
        _ = e.toggleZoom()   // zoom 4 → scale 1.0 pt/px
        #expect(approx(e.viewport.scale, 1.0))
        _ = e.aimBegan(at: CGPoint(x: 480, y: 270))
        let start = e.cursorPixel
        let a = e.aimChanged(to: CGPoint(x: 490, y: 270))   // 10 pt → 10 px × 0.5 = 5 px
        #expect(lastPointer(a)! == (start.x + 5, start.y, []))
    }

    @Test func subPixelMovementAccumulates() {
        var e = makeEngine(PointerEngineConfiguration(gain: 0.5))
        _ = e.aimBegan(at: CGPoint(x: 100, y: 50))   // cursor 400.0
        // Each 0.125 pt step = 0.5 px remote × 0.5 gain = 0.25 px (exact in binary floating point).
        var perStep: [[PointerAction]] = []
        for i in 1...8 { perStep.append(e.aimChanged(to: CGPoint(x: 100 + 0.125 * CGFloat(i), y: 50))) }
        #expect(perStep[0].isEmpty && perStep[1].isEmpty && perStep[2].isEmpty)
        #expect(perStep[3] == [.sendPointer(x: 401, y: 200, buttons: [])])
        #expect(perStep[4].isEmpty && perStep[5].isEmpty && perStep[6].isEmpty)
        #expect(perStep[7] == [.sendPointer(x: 402, y: 200, buttons: [])])
        #expect(e.cursor.x == 402)
    }

    @Test func endDoesNotClick() {
        var e = makeEngine()
        _ = e.aimBegan(at: CGPoint(x: 100, y: 50))
        _ = e.aimChanged(to: CGPoint(x: 120, y: 60))
        let a = e.aimEnded()
        #expect(a == [.loupe(visible: false)])
        #expect(e.mode == .idle)
        #expect(e.buttons.isEmpty)
        #expect(e.cursorPixel == (440, 220))
    }

    @Test func clampsToRemoteBounds() {
        var e = makeEngine(PointerEngineConfiguration(gain: 1))
        _ = e.aimBegan(at: CGPoint(x: 10, y: 10))
        var a = e.aimChanged(to: CGPoint(x: -5000, y: -5000))
        #expect(lastPointer(a)! == (0, 0, []))
        a = e.aimChanged(to: CGPoint(x: 50000, y: 50000))
        #expect(lastPointer(a)! == (3839, 2159, []))
        // Begin outside the view also clamps.
        _ = e.aimEnded()
        a = e.aimBegan(at: CGPoint(x: 2000, y: -30))
        #expect(lastPointer(a)! == (3839, 0, []))
    }

    @Test func clampedCursorDoesNotWindUp() {
        // After pushing against the edge, moving back moves immediately (cursor is clamped, not the finger).
        var e = makeEngine(PointerEngineConfiguration(gain: 1))
        _ = e.aimBegan(at: CGPoint(x: 1, y: 100))      // remote x = 4
        _ = e.aimChanged(to: CGPoint(x: -100, y: 100)) // clamp at 0
        let a = e.aimChanged(to: CGPoint(x: -99, y: 100))
        #expect(lastPointer(a)! == (4, 400, []))
    }

    @Test func verticalAimOffset() {
        var e = makeEngine(PointerEngineConfiguration(aimVerticalOffset: 20))
        let a = e.aimBegan(at: CGPoint(x: 100, y: 50))
        #expect(lastPointer(a)! == (400, 120, []))   // (50-20)/0.25
        // Offset applies only to the jump; tap is unaffected.
        _ = e.aimEnded()
        let t = e.tap(at: CGPoint(x: 100, y: 50))
        #expect(lastPointer(t)! == (400, 200, []))
    }

    @Test func changedWithoutBeginIsIgnored() {
        var e = makeEngine()
        #expect(e.aimChanged(to: CGPoint(x: 1, y: 1)).isEmpty)
        #expect(e.aimEnded().isEmpty)
        #expect(e.dragChanged(to: CGPoint(x: 1, y: 1)).isEmpty)
        #expect(e.dragEnded().isEmpty)
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: 100)).isEmpty)
        #expect(e.scrollEnded().isEmpty)
        #expect(e.pinchChanged(scale: 2, centroid: .zero).isEmpty)
        #expect(e.pinchEnded().isEmpty)
        #expect(e.mode == .idle)
    }

    @Test func nonFiniteInputIgnored() {
        var e = makeEngine()
        #expect(e.aimBegan(at: CGPoint(x: CGFloat.nan, y: 0)).isEmpty)
        #expect(e.tap(at: CGPoint(x: 0, y: CGFloat.infinity)).isEmpty)
        _ = e.aimBegan(at: CGPoint(x: 10, y: 10))
        #expect(e.aimChanged(to: CGPoint(x: CGFloat.nan, y: 0)).isEmpty)
        #expect(e.cursorPixel == (40, 40))
        var g = makeEngine(PointerEngineConfiguration(gain: .nan))
        _ = g.aimBegan(at: CGPoint(x: 10, y: 10))
        #expect(g.aimChanged(to: CGPoint(x: 100, y: 100)).isEmpty)  // gain NaN treated as 0
        #expect(g.cursorPixel == (40, 40))
    }

    @Test func viewportFollowsCursorWhenZoomed() {
        var e = makeEngine(PointerEngineConfiguration(gain: 1, followMargin: 40))
        _ = e.toggleZoom()   // zoom 4 around cursor (1920,1080) → scale 1
        let vp0 = e.viewport
        _ = e.aimBegan(at: CGPoint(x: 480, y: 270))
        // Move the finger 470 pt right: cursor moves 470 px right, beyond the 40pt margin of a 960pt view.
        let a = e.aimChanged(to: CGPoint(x: 950, y: 270))
        #expect(hasViewportChange(a))
        // Pointer event comes before the viewport change.
        if case .sendPointer = a.first! {} else { Issue.record("first action should be sendPointer") }
        #expect(e.viewport.offset.x < vp0.offset.x)
        let cv = e.viewport.viewPoint(forRemote: e.cursor)
        #expect(approx(cv.x, 960 - 40, 1e-6))
        checkInvariants(e.viewport)
    }

    @Test func noViewportChangeWhenFitted() {
        var e = makeEngine(PointerEngineConfiguration(gain: 1))
        _ = e.aimBegan(at: CGPoint(x: 0, y: 0))
        let a = e.aimChanged(to: CGPoint(x: 959, y: 539))
        #expect(!hasViewportChange(a))
    }
}

@Suite struct TapTests {
    @Test func tapBelowThresholdOnlyAims() {
        var e = makeEngine()
        let a = e.tap(at: CGPoint(x: 200, y: 100))
        #expect(a == [.sendPointer(x: 800, y: 400, buttons: []), .feedback(.aimed)])
        #expect(e.buttons.isEmpty)
    }

    @Test func tapAtThresholdClicksAtTapPoint() {
        var e = makeEngine()
        e = zoomed(e, to: 4.0)
        #expect(e.tapClicksDirectly)
        let tapPoint = CGPoint(x: 300.6, y: 200.2)
        let r = e.viewport.remotePoint(forView: tapPoint)
        let px = (Int(r.x.rounded(.down)), Int(r.y.rounded(.down)))
        let a = e.tap(at: tapPoint)
        let pointers = pointerEvents(a)
        #expect(pointers == [.sendPointer(x: px.0, y: px.1, buttons: []),
                             .sendPointer(x: px.0, y: px.1, buttons: [.left]),
                             .sendPointer(x: px.0, y: px.1, buttons: [])])
        #expect(a.last == .feedback(.click))
        #expect(e.buttons.isEmpty)
    }

    @Test func tapJustBelowThresholdAims() {
        var e = zoomed(makeEngine(), to: 3.99)
        #expect(!e.tapClicksDirectly)
        let a = e.tap(at: CGPoint(x: 300, y: 200))
        #expect(pointerEvents(a).count == 1)
        #expect(a.last == .feedback(.aimed))
    }

    @Test func customThreshold() {
        var e = zoomed(makeEngine(PointerEngineConfiguration(directTapMinZoom: 2)), to: 2)
        #expect(e.tapClicksDirectly)
        #expect(e.tap(at: CGPoint(x: 300, y: 200)).last == .feedback(.click))
        var f = makeEngine(PointerEngineConfiguration(directTapMinZoom: 1))
        #expect(f.tapClicksDirectly)   // threshold 1 → taps always click, even fitted
        #expect(f.tap(at: CGPoint(x: 10, y: 10)) == [
            .sendPointer(x: 40, y: 40, buttons: []), .sendPointer(x: 40, y: 40, buttons: [.left]),
            .sendPointer(x: 40, y: 40, buttons: []), .feedback(.click)])
    }

    @Test func tapOnLetterboxClampsIntoScreen() {
        // View wider than content: tapping the empty band left of the content aims at x=0.
        var e = PointerEngine(viewport: Viewport(remoteSize: CGSize(width: 3840, height: 2160), viewSize: CGSize(width: 1200, height: 540)))
        #expect(approx(e.viewport.offset.x, 120))
        let a = e.tap(at: CGPoint(x: 10, y: 100))
        #expect(lastPointer(a)! == (0, 400, []))
    }

    @Test func tapFinishesAnInterruptedGesture() {
        var e = makeEngine()
        _ = e.aimBegan(at: CGPoint(x: 10, y: 10))   // 'ended' never arrives
        let a = e.tap(at: CGPoint(x: 20, y: 20))
        #expect(a.first == .loupe(visible: false))
        #expect(e.mode == .idle)
    }

    @Test func smallButtonHitInTwoSteps() {
        // A 32x24 px (2x) button. Fitted (0.25 pt/px) a sloppy finger tap lands 20 px right, 16 px up.
        let button = CGRect(x: 2001, y: 1301, width: 32, height: 24)
        var e = makeEngine()
        let sloppy = CGPoint(x: button.midX * 0.25 + 5.0, y: button.midY * 0.25 - 4.0)
        let t = e.tap(at: sloppy)
        #expect(!t.contains { if case let .sendPointer(_, _, b) = $0 { return !b.isEmpty } else { return false } })
        let p = e.cursorPixel
        #expect(!button.contains(CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5)))
        // Fine-tune: start a drag on the cursor and move the finger by (needed px) × scale / gain.
        let startView = e.cursorViewPoint
        _ = e.aimBegan(at: startView)
        let need = CGVector(dx: button.midX - e.cursor.x, dy: button.midY - e.cursor.y)
        let s = e.viewport.scale, g = e.configuration.gain
        _ = e.aimChanged(to: CGPoint(x: startView.x + need.dx * s / g, y: startView.y + need.dy * s / g))
        #expect(e.aimEnded() == [.loupe(visible: false)])
        let a = e.click()
        let press = a.first { if case let .sendPointer(_, _, b) = $0 { return b == [.left] } else { return false } }
        guard case let .sendPointer(x, y, _)? = press else { Issue.record("no press"); return }
        #expect(button.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)))
        #expect(x == Int(button.midX) && y == Int(button.midY))
    }

    @Test func directTapAccuracyAtZoom4() {
        // At zoom 4 (1 pt per px), tapping anywhere inside a 24 px tall button's view rect hits it.
        var e = zoomed(makeEngine(), to: 4)
        let vr = e.viewport.visibleRemoteRect
        let button = CGRect(x: vr.minX + 300, y: vr.minY + 200, width: 40, height: 24)
        let tl = e.viewport.viewPoint(forRemote: button.origin)
        for dx in stride(from: 0.0, to: 40.0, by: 3.7) {
            for dy in stride(from: 0.0, to: 24.0, by: 2.9) {
                let a = e.tap(at: CGPoint(x: tl.x + dx, y: tl.y + dy))
                guard let (x, y, _) = lastPointer(a) else { Issue.record("no event"); continue }
                #expect(button.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)))
            }
        }
    }
}

/// Zooms the engine (around the cursor) to an exact relative zoom.
func zoomed(_ e: PointerEngine, to z: CGFloat) -> PointerEngine {
    var e = e
    var c = e.configuration
    c.toggleZoomLevel = z
    e.configuration = c
    _ = e.toggleZoom()
    #expect(approx(e.viewport.zoomRelativeToFit, z, 1e-9))
    e.configuration.toggleZoomLevel = 4
    return e
}

@Suite struct ClickTests {
    @Test func clickSendsMoveFirstTimeThenPressRelease() {
        var e = makeEngine()
        let a = e.click()
        #expect(a == [.sendPointer(x: 1920, y: 1080, buttons: []),
                      .sendPointer(x: 1920, y: 1080, buttons: [.left]),
                      .sendPointer(x: 1920, y: 1080, buttons: []),
                      .feedback(.click)])
        let b = e.click()
        #expect(b == [.sendPointer(x: 1920, y: 1080, buttons: [.left]),
                      .sendPointer(x: 1920, y: 1080, buttons: []),
                      .feedback(.click)])
    }

    @Test func clickAfterAimIsAtCursor() {
        var e = makeEngine()
        _ = e.tap(at: CGPoint(x: 100, y: 100))
        #expect(e.click() == [.sendPointer(x: 400, y: 400, buttons: [.left]),
                              .sendPointer(x: 400, y: 400, buttons: []),
                              .feedback(.click)])
    }

    @Test func doubleClick() {
        var e = makeEngine()
        _ = e.tap(at: CGPoint(x: 100, y: 100))
        #expect(e.doubleClick() == [
            .sendPointer(x: 400, y: 400, buttons: [.left]), .sendPointer(x: 400, y: 400, buttons: []),
            .sendPointer(x: 400, y: 400, buttons: [.left]), .sendPointer(x: 400, y: 400, buttons: []),
            .feedback(.doubleClick)])
    }

    @Test func rightClickAndTwoFingerTap() {
        var e = makeEngine()
        _ = e.tap(at: CGPoint(x: 100, y: 100))
        let expected: [PointerAction] = [.sendPointer(x: 400, y: 400, buttons: [.right]),
                                         .sendPointer(x: 400, y: 400, buttons: []), .feedback(.rightClick)]
        #expect(e.rightClick() == expected)
        #expect(e.twoFingerTap() == expected)   // at the cursor, not at a tap location
    }

    @Test func clickDuringDragReleasesFirst() {
        var e = makeEngine()
        _ = e.dragBegan(at: CGPoint(x: 0, y: 0))
        let a = e.click()
        #expect(Array(a.prefix(3)) == [.loupe(visible: false), .sendPointer(x: 1920, y: 1080, buttons: []), .feedback(.dragEnded)])
        #expect(e.buttons.isEmpty)
        #expect(a.last == .feedback(.click))
    }
}

@Suite struct DragTests {
    @Test func longPressDrag() {
        var e = makeEngine()
        _ = e.tap(at: CGPoint(x: 100, y: 100))          // cursor at (400,400)
        var a = e.dragBegan(at: CGPoint(x: 500, y: 300)) // finger elsewhere: button goes down at the CURSOR
        #expect(a == [.loupe(visible: true), .sendPointer(x: 400, y: 400, buttons: [.left]), .feedback(.dragBegan)])
        #expect(e.mode == .dragging && e.buttons == [.left])
        a = e.dragChanged(to: CGPoint(x: 510, y: 305))   // +10,+5 pt → +20,+10 px
        #expect(a == [.sendPointer(x: 420, y: 410, buttons: [.left])])
        a = e.dragEnded()
        #expect(a == [.loupe(visible: false), .sendPointer(x: 420, y: 410, buttons: []), .feedback(.dragEnded)])
        #expect(e.mode == .idle && e.buttons.isEmpty)
    }

    @Test func dragInterruptedByPinchReleasesButton() {
        var e = makeEngine()
        _ = e.dragBegan(at: CGPoint(x: 10, y: 10))
        let a = e.pinchBegan(centroid: CGPoint(x: 400, y: 200))
        #expect(a == [.loupe(visible: false), .sendPointer(x: 1920, y: 1080, buttons: []), .feedback(.dragEnded)])
        #expect(e.mode == .pinching && e.buttons.isEmpty)
    }

    @Test func aimBeginDuringDragReleasesButtonFirst() {
        var e = makeEngine()
        _ = e.dragBegan(at: CGPoint(x: 10, y: 10))
        let a = e.aimBegan(at: CGPoint(x: 100, y: 50))
        #expect(a == [.loupe(visible: false), .sendPointer(x: 1920, y: 1080, buttons: []), .feedback(.dragEnded),
                      .loupe(visible: true), .sendPointer(x: 400, y: 200, buttons: [])])
    }

    @Test func cancelReleasesEverything() {
        var e = makeEngine()
        #expect(e.cancel().isEmpty)
        _ = e.dragBegan(at: CGPoint(x: 10, y: 10))
        #expect(e.cancel() == [.loupe(visible: false), .sendPointer(x: 1920, y: 1080, buttons: []), .feedback(.dragEnded)])
        _ = e.aimBegan(at: CGPoint(x: 10, y: 10))
        #expect(e.cancel() == [.loupe(visible: false)])
        #expect(e.mode == .idle)
    }

    @Test func dragClampsAndSendsButtonsHeld() {
        var e = makeEngine(PointerEngineConfiguration(gain: 1))
        _ = e.dragBegan(at: CGPoint(x: 10, y: 10))
        let a = e.dragChanged(to: CGPoint(x: 10_000, y: -10_000))
        #expect(lastPointer(a)! == (3839, 0, [.left]))
    }
}

@Suite struct ScrollTests {
    @Test func naturalScrollingAccumulates() {
        var e = makeEngine()   // 12 pt per step, natural
        #expect(e.scrollBegan().isEmpty)
        #expect(e.mode == .scrolling)
        // Fingers up 30 pt → content up → wheel DOWN 2 clicks (remainder 6 pt).
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -30)) == [.sendScroll(x: 1920, y: 1080, deltaX: 0, deltaY: 2, buttons: [])])
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -5)).isEmpty)   // remainder 11
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -1)) == [.sendScroll(x: 1920, y: 1080, deltaX: 0, deltaY: 1, buttons: [])])
        // Reversal works through the remainder (0 now): down 12 → wheel up 1.
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: 12)) == [.sendScroll(x: 1920, y: 1080, deltaX: 0, deltaY: -1, buttons: [])])
        #expect(e.scrollEnded().isEmpty)
        #expect(e.mode == .idle)
    }

    @Test func traditionalScrolling() {
        var e = makeEngine(PointerEngineConfiguration(naturalScrolling: false))
        _ = e.scrollBegan()
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -24)) == [.sendScroll(x: 1920, y: 1080, deltaX: 0, deltaY: -2, buttons: [])])
        #expect(e.scrollChanged(by: CGVector(dx: 25, dy: 0)) == [.sendScroll(x: 1920, y: 1080, deltaX: 2, deltaY: 0, buttons: [])])
    }

    @Test func horizontalNatural() {
        var e = makeEngine()
        _ = e.scrollBegan()
        // Fingers left → content left → wheel RIGHT.
        #expect(e.scrollChanged(by: CGVector(dx: -36, dy: 0)) == [.sendScroll(x: 1920, y: 1080, deltaX: 3, deltaY: 0, buttons: [])])
    }

    @Test func remainderDiscardedOnEnd() {
        var e = makeEngine()
        _ = e.scrollBegan()
        _ = e.scrollChanged(by: CGVector(dx: 0, dy: -11))
        _ = e.scrollEnded()
        _ = e.scrollBegan()
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -11)).isEmpty)
    }

    @Test func capPerUpdate() {
        var e = makeEngine()
        _ = e.scrollBegan()
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -1200)) == [.sendScroll(x: 1920, y: 1080, deltaX: 0, deltaY: 10, buttons: [])])
        // The excess was dropped, not queued.
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -1)).isEmpty)
    }

    @Test func scrollAtCursorAfterAim() {
        var e = makeEngine()
        _ = e.tap(at: CGPoint(x: 100, y: 100))
        _ = e.scrollBegan()
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -12)) == [.sendScroll(x: 400, y: 400, deltaX: 0, deltaY: 1, buttons: [])])
    }

    @Test func badConfigOrInput() {
        var e = makeEngine(PointerEngineConfiguration(scrollPointsPerStep: 0))
        _ = e.scrollBegan()
        #expect(e.scrollChanged(by: CGVector(dx: 0, dy: -100)).isEmpty)
        var f = makeEngine()
        _ = f.scrollBegan()
        #expect(f.scrollChanged(by: CGVector(dx: CGFloat.nan, dy: -100)).isEmpty)
        #expect(f.scrollChanged(by: CGVector(dx: 0, dy: -12)).count == 1)   // remainder not poisoned
    }

    @Test func scrollDoesNotMoveCursor() {
        var e = makeEngine()
        _ = e.scrollBegan()
        _ = e.scrollChanged(by: CGVector(dx: 50, dy: 50))
        #expect(e.cursorPixel == (1920, 1080))
    }
}

@Suite struct PinchTests {
    @Test func pinchZoomsAroundCentroid() {
        var e = makeEngine()
        let c = CGPoint(x: 300, y: 200)
        let r0 = e.viewport.remotePoint(forView: c)
        #expect(e.pinchBegan(centroid: c).isEmpty)
        let a = e.pinchChanged(scale: 2, centroid: c)
        #expect(a == [.viewportChanged(e.viewport)])
        #expect(approx(e.viewport.zoomRelativeToFit, 2))
        #expect(approx(e.viewport.remotePoint(forView: c), r0, 1e-6))
        _ = e.pinchChanged(scale: 4, centroid: c)     // cumulative scale 4 → relative zoom 4
        #expect(approx(e.viewport.zoomRelativeToFit, 4))
        #expect(approx(e.viewport.remotePoint(forView: c), r0, 1e-6))
        _ = e.pinchEnded()
        #expect(e.mode == .idle)
        #expect(e.tapClicksDirectly)
    }

    @Test func pinchCentroidPans() {
        var e = makeEngine()
        _ = e.pinchBegan(centroid: CGPoint(x: 480, y: 270))
        _ = e.pinchChanged(scale: 4, centroid: CGPoint(x: 480, y: 270))
        let o = e.viewport.offset
        let r = e.viewport.remotePoint(forView: CGPoint(x: 480, y: 270))
        _ = e.pinchChanged(scale: 4, centroid: CGPoint(x: 500, y: 260))   // move +20,-10 without scaling
        #expect(approx(e.viewport.offset.x, o.x + 20) && approx(e.viewport.offset.y, o.y - 10))
        // Content follows the fingers: the remote point stays under the centroid.
        #expect(approx(e.viewport.remotePoint(forView: CGPoint(x: 500, y: 260)), r, 1e-6))
        checkInvariants(e.viewport)
    }

    @Test func pinchOutBelowFitClamps() {
        var e = makeEngine()
        _ = e.pinchBegan(centroid: CGPoint(x: 100, y: 100))
        #expect(e.pinchChanged(scale: 0.3, centroid: CGPoint(x: 100, y: 100)).isEmpty)  // already fitted
        #expect(e.viewport.isFitted)
        #expect(e.pinchChanged(scale: 0, centroid: .zero).isEmpty)
        #expect(e.pinchChanged(scale: -1, centroid: .zero).isEmpty)
        #expect(e.pinchChanged(scale: .nan, centroid: .zero).isEmpty)
    }

    @Test func pinchDoesNotMoveCursorOrSend() {
        var e = makeEngine()
        _ = e.pinchBegan(centroid: CGPoint(x: 100, y: 100))
        let a = e.pinchChanged(scale: 3, centroid: CGPoint(x: 120, y: 90))
        #expect(pointerEvents(a).isEmpty)
        #expect(e.cursorPixel == (1920, 1080))
    }
}

@Suite struct ViewportCommandTests {
    @Test func toggleZoom() {
        var e = makeEngine()
        _ = e.tap(at: CGPoint(x: 100, y: 100))   // cursor (400,400)
        let a = e.toggleZoom()
        #expect(a.count == 1 && hasViewportChange(a))
        #expect(approx(e.viewport.zoomRelativeToFit, 4))
        #expect(e.tapClicksDirectly)
        // Cursor near top-left: centered as much as clamping allows → it is visible.
        #expect(e.viewport.visibleRemoteRect.contains(e.cursor))
        _ = e.toggleZoom()
        #expect(e.viewport.isFitted)
        #expect(e.fit().isEmpty)   // already fitted
    }

    @Test func setRemoteSizeClampsCursor() {
        var e = makeEngine(PointerEngineConfiguration(gain: 1))
        _ = e.aimBegan(at: CGPoint(x: 10, y: 10))
        _ = e.aimChanged(to: CGPoint(x: 5000, y: 5000))
        _ = e.aimEnded()
        #expect(e.cursorPixel == (3839, 2159))
        let a = e.setRemoteSize(CGSize(width: 1920, height: 1080))
        #expect(a == [.viewportChanged(e.viewport)])
        #expect(e.cursorPixel == (1919, 1079))
        // Next click re-sends the position first (lastSent was invalidated).
        #expect(e.click().first == .sendPointer(x: 1919, y: 1079, buttons: []))
    }

    @Test func setViewSize() {
        var e = makeEngine()
        #expect(e.setViewSize(CGSize(width: 960, height: 540)).isEmpty)
        let a = e.setViewSize(CGSize(width: 678, height: 381))
        #expect(a == [.viewportChanged(e.viewport)])
        #expect(e.viewport.isFitted)
        // Zoomed: cursor stays visible after a resize.
        _ = e.toggleZoom()
        _ = e.setViewSize(CGSize(width: 300, height: 200))
        let cv = e.viewport.viewPoint(forRemote: e.cursor)
        #expect(cv.x >= 0 && cv.x <= 300 && cv.y >= 0 && cv.y <= 200)
    }

    @Test func invalidViewportIgnoresInput() {
        var e = PointerEngine(viewport: Viewport(remoteSize: .zero, viewSize: CGSize(width: 100, height: 100)))
        #expect(e.cursorPixel == (0, 0))
        #expect(e.tap(at: CGPoint(x: 5, y: 5)).isEmpty)
        #expect(e.aimBegan(at: CGPoint(x: 5, y: 5)).isEmpty)
        #expect(e.click().isEmpty)
        #expect(e.dragBegan(at: .zero).isEmpty)
        #expect(e.mode == .idle)
    }

    @Test func hugeRemoteSizeDoesNotTrap() {
        var e = PointerEngine(viewport: Viewport(remoteSize: CGSize(width: 1e30, height: 1e30), viewSize: CGSize(width: 100, height: 100)))
        let a = e.tap(at: CGPoint(x: 99, y: 99))
        #expect(lastPointer(a)! == (65535, 65535, []))
    }
}
