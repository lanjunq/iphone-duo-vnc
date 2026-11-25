import Foundation
import CoreGraphics
import Testing
@testable import DuoVNCKit

@Suite struct ToolbarLayoutTests {
    let items = ToolbarCommand.layoutItems

    func assertSane(_ p: ToolbarLayout.Placement, frame: CGRect, keepOut: [CGRect] = []) {
        let rects = Array(p.frames.values)
        for r in rects {
            #expect(frame.insetBy(dx: -0.001, dy: -0.001).contains(r))
            #expect(r.width >= 44 - 0.001 || r.height >= 44 - 0.001)
            for k in keepOut { #expect(!r.intersects(k)) }
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(rects[i].intersection(rects[j]).width <= 0.001 || rects[i].intersection(rects[j]).height <= 0.001)
            }
        }
        #expect(p.frames.count + p.hidden.count == items.count)
    }

    @Test func innerLandscapeBottomBarFitsEverythingInTwoRows() {
        let frame = CGRect(x: 0, y: 500, width: 890, height: 126)
        let p = ToolbarLayout.layout(items: items, in: frame, axis: .bottom)
        #expect(p.hidden.isEmpty)
        #expect(p.lanes == 2)
        assertSane(p, frame: frame)
        // The click button is the first item and twice as wide as a normal one.
        let click = p.frames["click"]!, right = p.frames["rightClick"]!
        #expect(abs(click.width - 2 * right.width) < 1)
        #expect(click.minX < right.minX)
    }

    @Test func outerLandscapeHidesLowPriorityItems() {
        let frame = CGRect(x: 0, y: 381, width: 678, height: 85)
        let p = ToolbarLayout.layout(items: items, in: frame, axis: .bottom)
        #expect(p.lanes == 1)
        #expect(!p.hidden.isEmpty)
        for essential in ["click", "rightClick", "keyboard", "password", "disconnect", "more"] {
            #expect(p.frames[essential] != nil)
        }
        // Hidden ones are the least important.
        let hiddenPriorities = p.hidden.compactMap { ToolbarCommand(rawValue: $0)?.priority }
        let visiblePriorities = p.frames.keys.compactMap { ToolbarCommand(rawValue: $0)?.priority }
        #expect(hiddenPriorities.min()! > visiblePriorities.max()!)
        assertSane(p, frame: frame)
    }

    @Test func sideBarStacksColumns() {
        let frame = CGRect(x: 580, y: 0, width: 310, height: 326)
        let p = ToolbarLayout.layout(items: items, in: frame, axis: .side)
        #expect(p.hidden.isEmpty)
        assertSane(p, frame: frame)
        let click = p.frames["click"]!
        #expect(click.height > click.width * 0.5)
    }

    @Test func foldKeepOutSplitsRows() {
        let frame = CGRect(x: 0, y: 500, width: 890, height: 126)
        let fold = CGRect(x: 435, y: 500, width: 20, height: 126)
        let p = ToolbarLayout.layout(items: items, in: frame, axis: .bottom, keepOut: [fold])
        assertSane(p, frame: frame, keepOut: [fold])
        #expect(p.frames.values.contains { $0.maxX <= 435 })
        #expect(p.frames.values.contains { $0.minX >= 455 })
    }

    @Test func degenerateFramesHideEverything() {
        let p = ToolbarLayout.layout(items: items, in: .zero, axis: .bottom)
        #expect(p.frames.isEmpty)
        #expect(p.hidden.count == items.count)
        let q = ToolbarLayout.layout(items: [], in: CGRect(x: 0, y: 0, width: 100, height: 100), axis: .bottom)
        #expect(q.frames.isEmpty)
        let n = ToolbarLayout.layout(items: items, in: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), axis: .side)
        #expect(n.frames.isEmpty)
    }

    @Test func lanesPackTowardOuterEdgeAndCapThickness() {
        // Outer screen portrait: lots of vertical room. Lanes are at most 72 pt and sit at the bottom.
        let frame = CGRect(x: 0, y: 262, width: 466, height: 416)
        let p = ToolbarLayout.layout(items: items, in: frame, axis: .bottom)
        #expect(p.hidden.isEmpty)
        for r in p.frames.values { #expect(r.height <= 72.001) }
        let maxY = p.frames.values.map { $0.maxY }.max()!
        #expect(abs(maxY - (frame.maxY - 4)) < 0.01)
    }

    @Test func everyCommandHasDistinctPriorityAndTitle() {
        #expect(Set(ToolbarCommand.allCases.map { $0.priority }).count == ToolbarCommand.allCases.count)
        #expect(ToolbarCommand.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(ToolbarCommand.command.modifier == .command)
        #expect(ToolbarCommand.escape.specialKey == .escape)
        #expect(ToolbarCommand.click.weight == 2)
    }
}

@Suite struct FoldLayoutTests {
    let aspect: CGFloat = 16.0 / 9.0
    let bounds = CGRect(x: 0, y: 0, width: 890, height: 626)

    @Test func noDivisionMatchesPlainLayout() {
        let input = LayoutEngine.Input(bounds: bounds, remoteAspectRatio: aspect)
        #expect(LayoutEngine.layout(input, divisions: []) == LayoutEngine.layout(input))
    }

    @Test func laptopPostureSplitsAtTheFold() {
        let fold = CGRect(x: 0, y: 303, width: 890, height: 20)
        let o = LayoutEngine.layout(.init(bounds: bounds, remoteAspectRatio: aspect), divisions: [fold])
        #expect(o.axis == .bottom)
        #expect(o.desktopFrame == CGRect(x: 0, y: 0, width: 890, height: 303))
        #expect(o.toolbarFrame == CGRect(x: 0, y: 323, width: 890, height: 303))
        #expect(!o.desktopFrame.intersects(fold))
        #expect(!o.toolbarFrame.intersects(fold))
    }

    @Test func bookPostureDesktopOnOneSide() {
        let fold = CGRect(x: 435, y: 0, width: 20, height: 626)
        let o = LayoutEngine.layout(.init(bounds: bounds, remoteAspectRatio: aspect), divisions: [fold])
        #expect(o.axis == .side)
        #expect(o.desktopFrame == CGRect(x: 0, y: 0, width: 435, height: 626))
        #expect(o.toolbarFrame == CGRect(x: 455, y: 0, width: 435, height: 626))
    }

    @Test func foldTooCloseToEdgeFallsBackWithKeepOut() {
        // Horizontal division leaving only 30 pt below: plain layout, division as keep-out.
        let fold = CGRect(x: 0, y: 586, width: 890, height: 10)
        let o = LayoutEngine.layout(.init(bounds: bounds, remoteAspectRatio: aspect), divisions: [fold])
        #expect(o.axis == .bottom)
        #expect(o.desktopFrame.height == 500)
        #expect(o.toolbarKeepOutRects == [CGRect(x: 0, y: 586, width: 890, height: 10)])
    }

    @Test func divisionOutsideUsableAreaIgnored() {
        let input = LayoutEngine.Input(bounds: bounds, remoteAspectRatio: aspect)
        let o = LayoutEngine.layout(input, divisions: [CGRect(x: 2000, y: 0, width: 10, height: 10)])
        #expect(o == LayoutEngine.layout(input))
    }
}

@Suite struct LoupeGeometryTests {
    @Test func sourceSideMagnifiesTheView() {
        // Fitted 3840 px into 890 pt: scale 0.2318. A 140 pt loupe at 4x shows ~151 px.
        let s = LoupeGeometry.sourceSide(loupeSize: 140, viewportScale: 890.0 / 3840.0)
        #expect(s == 152 || s == 150)
        #expect(Int(s) % 2 == 0)
        #expect(LoupeGeometry.sourceSide(loupeSize: 140, viewportScale: 100) == 16)
        #expect(LoupeGeometry.sourceSide(loupeSize: 140, viewportScale: 0.001) == 512)
        #expect(LoupeGeometry.sourceSide(loupeSize: 140, viewportScale: .nan) == 16)
    }

    @Test func sourceRectCentersAndClamps() {
        let size = CGSize(width: 3840, height: 2160)
        #expect(LoupeGeometry.sourceRect(cursorPixel: (1000, 1000), remoteSize: size, side: 100) == CGRect(x: 950, y: 950, width: 100, height: 100))
        #expect(LoupeGeometry.sourceRect(cursorPixel: (3, 2), remoteSize: size, side: 100) == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(LoupeGeometry.sourceRect(cursorPixel: (3839, 2159), remoteSize: size, side: 100) == CGRect(x: 3740, y: 2060, width: 100, height: 100))
        #expect(LoupeGeometry.sourceRect(cursorPixel: (5, 5), remoteSize: CGSize(width: 40, height: 30), side: 100) == CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(LoupeGeometry.sourceRect(cursorPixel: (0, 0), remoteSize: .zero, side: 100) == .zero)
    }

    @Test func crosshairFollowsClampedCursor() {
        let src = CGRect(x: 0, y: 0, width: 100, height: 100)
        let p = LoupeGeometry.crosshairPoint(cursorPixel: (9, 49), source: src, loupeSize: CGSize(width: 200, height: 200))
        #expect(p == CGPoint(x: 19, y: 99))
        let c = LoupeGeometry.crosshairPoint(cursorPixel: (1000, 1000), source: CGRect(x: 950, y: 950, width: 100, height: 100), loupeSize: CGSize(width: 100, height: 100))
        #expect(c == CGPoint(x: 50.5, y: 50.5))
    }

    @Test func frameAvoidsCursor() {
        let b = CGRect(x: 0, y: 0, width: 890, height: 500)
        // Cursor on the left, low → top right.
        #expect(LoupeGeometry.frame(cursorView: CGPoint(x: 100, y: 400), bounds: b, size: 140) == CGRect(x: 738, y: 12, width: 140, height: 140))
        // Cursor on the right → top left.
        #expect(LoupeGeometry.frame(cursorView: CGPoint(x: 800, y: 400), bounds: b, size: 140) == CGRect(x: 12, y: 12, width: 140, height: 140))
        // Cursor near the top on the right → bottom left.
        #expect(LoupeGeometry.frame(cursorView: CGPoint(x: 800, y: 50), bounds: b, size: 140) == CGRect(x: 12, y: 348, width: 140, height: 140))
        // Tiny bounds shrink the loupe instead of overflowing.
        let tiny = LoupeGeometry.frame(cursorView: .zero, bounds: CGRect(x: 0, y: 0, width: 100, height: 60), size: 140)
        #expect(tiny.height == 36)
    }
}

@Suite struct HostKeyTrustTests {
    @Test func verdicts() {
        #expect(HostKeyTrust.evaluate(pinned: nil, presented: "ab") == .firstUse)
        #expect(HostKeyTrust.evaluate(pinned: "", presented: "ab") == .firstUse)
        #expect(HostKeyTrust.evaluate(pinned: "AB:CD", presented: "abcd") == .trusted)
        #expect(HostKeyTrust.evaluate(pinned: "abcd", presented: "abce") == .mismatch(pinned: "abcd"))
    }

    @Test func formatting() {
        #expect(HostKeyTrust.formatted("abcdef0123") == "ABCD EF01 23")
        #expect(HostKeyTrust.formatted(String(repeating: "a", count: 64)).split(separator: " ").count == 16)
    }
}

@Suite struct HardwareKeyMapTests {
    @Test func specialKeysAndModifiers() {
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x28) == 0xff0d)
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x58) == 0xff0d)
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x29) == 0xff1b)
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x2A) == 0xff08)
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x3A) == 0xffbe)   // F1
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x45) == 0xffc9)   // F12
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x50) == 0xff51)   // left
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x52) == 0xff52)   // up
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0xE3) == 0xffeb)   // left GUI = command
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0xE7) == 0xffeb)
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0xE1) == 0xffe1)
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x04) == nil)      // "a" is a character key
        #expect(HardwareKeyMap.keysym(forHIDUsage: 0x39) == nil)      // caps lock not forwarded
        #expect(HardwareKeyMap.isModifier(usage: 0xE2))
        #expect(!HardwareKeyMap.isModifier(usage: 0x28))
    }

    @Test func characterKeys() {
        #expect(HardwareKeyMap.characterKeysyms(characters: "A", charactersIgnoringModifiers: "a", commandControlOrOptionHeld: false) == [0x41])
        #expect(HardwareKeyMap.characterKeysyms(characters: "ç", charactersIgnoringModifiers: "c", commandControlOrOptionHeld: true) == [0x63])
        #expect(HardwareKeyMap.characterKeysyms(characters: "", charactersIgnoringModifiers: "e", commandControlOrOptionHeld: false) == [0x65])
        #expect(HardwareKeyMap.characterKeysyms(characters: "", charactersIgnoringModifiers: "", commandControlOrOptionHeld: false).isEmpty)
        #expect(HardwareKeyMap.characterKeysyms(characters: "中", charactersIgnoringModifiers: "中", commandControlOrOptionHeld: false) == [0x0100_4E2D])
    }
}

@Suite struct CursorImageTests {
    @Test func premultiplies() {
        let src = Data([10, 20, 30, 0, 10, 20, 30, 255, 200, 100, 50, 128])
        let out = CursorImage.premultipliedBGRA(src, width: 3, height: 1)!
        #expect(Array(out) == [0, 0, 0, 0, 10, 20, 30, 255, 100, 50, 25, 128])
        #expect(CursorImage.premultipliedBGRA(src, width: 2, height: 1) == nil)
        #expect(CursorImage.premultipliedBGRA(Data(), width: 0, height: 0) == nil)
    }

    @Test func invisibility() {
        #expect(CursorImage.isInvisible(Data([1, 2, 3, 0]), width: 1, height: 1))
        #expect(!CursorImage.isInvisible(Data([1, 2, 3, 255]), width: 1, height: 1))
        #expect(CursorImage.isInvisible(Data(), width: 0, height: 0))
    }
}
