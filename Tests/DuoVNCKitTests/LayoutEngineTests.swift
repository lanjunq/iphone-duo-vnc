import Foundation
import CoreGraphics
import Testing
@testable import DuoVNCKit

@Suite struct LayoutEngineTests {
    let aspect: CGFloat = 3840.0 / 2160.0

    func checkTiling(_ o: LayoutEngine.Output, usable: CGRect) {
        #expect(o.desktopFrame.union(o.toolbarFrame).equalTo(usable) || usable.isEmpty)
        #expect(o.desktopFrame.intersection(o.toolbarFrame).isEmpty)
    }

    @Test func duoInnerLandscapeUsesBottomBar() {
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 890, height: 626), remoteAspectRatio: aspect))
        #expect(o.axis == .bottom)
        #expect(o.desktopFrame == CGRect(x: 0, y: 0, width: 890, height: 500))   // floor(890/16*9 = 500.625)
        #expect(o.toolbarFrame == CGRect(x: 0, y: 500, width: 890, height: 126))
        #expect(o.toolbarFrame.height >= LayoutEngine.minimumToolbarThickness)
        checkTiling(o, usable: CGRect(x: 0, y: 0, width: 890, height: 626))
    }

    @Test func duoOuterLandscape() {
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 678, height: 466), remoteAspectRatio: aspect))
        #expect(o.axis == .bottom)
        #expect(o.desktopFrame.height == 381)
        #expect(o.toolbarFrame.height == 85)
    }

    @Test func wideScreenUsesSideBar() {
        // 1000x400: bottom bar would leave 344pt height → 611 wide; side bar gives 400 tall → 711 wide.
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 1000, height: 400), remoteAspectRatio: aspect))
        #expect(o.axis == .side)
        #expect(o.desktopFrame == CGRect(x: 0, y: 0, width: 711, height: 400))
        #expect(o.toolbarFrame == CGRect(x: 711, y: 0, width: 289, height: 400))
        checkTiling(o, usable: CGRect(x: 0, y: 0, width: 1000, height: 400))
    }

    @Test func minimumThicknessRespected() {
        // Exactly 16:9 container: the toolbar still gets 56 pt.
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 1600, height: 900), remoteAspectRatio: aspect))
        let t = o.axis == .bottom ? o.toolbarFrame.height : o.toolbarFrame.width
        #expect(t >= 56)
    }

    @Test func portraitPutsEverythingLeftoverInBottomBar() {
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 626, height: 890), remoteAspectRatio: aspect))
        #expect(o.axis == .bottom)
        #expect(o.desktopFrame.height == 352)
        #expect(o.toolbarFrame.height == 538)
    }

    @Test func safeAreaAndKeyboard() {
        let input = LayoutEngine.Input(bounds: CGRect(x: 0, y: 0, width: 890, height: 626),
                                       safeAreaInsets: LayoutInsets(top: 20, left: 44, bottom: 21, right: 44),
                                       remoteAspectRatio: aspect, keyboardHeight: 250)
        let o = LayoutEngine.layout(input)
        let usable = CGRect(x: 44, y: 20, width: 802, height: 356)
        #expect(o.desktopFrame.minX == 44 && o.desktopFrame.minY == 20)
        #expect(o.toolbarFrame.maxY == 376)          // sits on top of the keyboard
        checkTiling(o, usable: usable)
        // Keyboard smaller than the safe-area bottom: safe area wins.
        let o2 = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 890, height: 626),
                                          safeAreaInsets: LayoutInsets(bottom: 30), remoteAspectRatio: aspect, keyboardHeight: 10))
        #expect(o2.toolbarFrame.maxY == 596)
    }

    @Test func foldKeepOut() {
        let fold = CGRect(x: 440, y: 0, width: 10, height: 626)
        let camera = CGRect(x: 0, y: 0, width: 30, height: 30)   // only over the desktop: no keep-out
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 890, height: 626),
                                          obstructedRects: [fold, camera], remoteAspectRatio: aspect))
        #expect(o.toolbarKeepOutRects == [CGRect(x: 440, y: 500, width: 10, height: 126)])
    }

    @Test func garbageInputsDoNotTrap() {
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: 30, height: 20), remoteAspectRatio: .nan))
        #expect(o.desktopFrame.width >= 0 && o.toolbarFrame.width >= 0)
        let o2 = LayoutEngine.layout(.init(bounds: .zero, safeAreaInsets: LayoutInsets(top: .nan, left: -5, bottom: .infinity, right: 3),
                                           obstructedRects: [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)],
                                           remoteAspectRatio: 0, keyboardHeight: -100))
        #expect(o2.desktopFrame.width == 0 || o2.desktopFrame.isEmpty)
        #expect(o2.toolbarKeepOutRects.isEmpty)
        let o3 = LayoutEngine.layout(.init(bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100), remoteAspectRatio: aspect))
        #expect(o3.desktopFrame == .zero || o3.desktopFrame.isEmpty)
    }

    @Test func nonZeroOrigin() {
        let o = LayoutEngine.layout(.init(bounds: CGRect(x: 100, y: 50, width: 890, height: 626), remoteAspectRatio: aspect))
        #expect(o.desktopFrame.origin == CGPoint(x: 100, y: 50))
        #expect(o.toolbarFrame.maxY == 676)
    }
}
