import Foundation
import Testing
@testable import DuoVNCKit

private func downUp(_ k: UInt32) -> [KeyEvent] { [KeyEvent(keysym: k, down: true), KeyEvent(keysym: k, down: false)] }
private let shiftDown = KeyEvent(keysym: 0xffe1, down: true)
private let shiftUp = KeyEvent(keysym: 0xffe1, down: false)

@Suite struct KeyMapperTests {
    @Test func latin1Direct() {
        #expect(KeyMapper.keysym(for: "a") == 0x61)
        #expect(KeyMapper.keysym(for: "A") == 0x41)
        #expect(KeyMapper.keysym(for: " ") == 0x20)
        #expect(KeyMapper.keysym(for: "~") == 0x7e)
        #expect(KeyMapper.keysym(for: "\u{a0}") == 0xa0)
        #expect(KeyMapper.keysym(for: "é") == 0xe9)
        #expect(KeyMapper.keysym(for: "ÿ") == 0xff)
    }

    @Test func unicodeOffset() {
        #expect(KeyMapper.keysym(for: "€") == 0x0100_20ac)
        #expect(KeyMapper.keysym(for: "中") == 0x0100_4e2d)
        #expect(KeyMapper.keysym(for: "😀") == 0x0101_f600)
        #expect(KeyMapper.keysym(for: "\u{100}") == 0x0100_0100)
    }

    @Test func controlCharacters() {
        #expect(KeyMapper.keysym(for: "\n") == 0xff0d)
        #expect(KeyMapper.keysym(for: "\r") == 0xff0d)
        #expect(KeyMapper.keysym(for: "\t") == 0xff09)
        #expect(KeyMapper.keysym(for: "\u{8}") == 0xff08)
        #expect(KeyMapper.keysym(for: "\u{1b}") == 0xff1b)
        #expect(KeyMapper.keysym(for: "\u{0}") == nil)
        #expect(KeyMapper.keysym(for: "\u{7f}") == nil)
        #expect(KeyMapper.keysym(for: "\u{85}") == nil)
        #expect(KeyMapper.keysyms(for: "\r\n") == [0xff0d])
    }

    @Test func specialKeys() {
        let expected: [(SpecialKey, UInt32)] = [
            (.returnKey, 0xff0d), (.tab, 0xff09), (.escape, 0xff1b), (.backspace, 0xff08), (.forwardDelete, 0xffff),
            (.left, 0xff51), (.up, 0xff52), (.right, 0xff53), (.down, 0xff54),
            (.home, 0xff50), (.end, 0xff57), (.pageUp, 0xff55), (.pageDown, 0xff56), (.space, 0x20),
            (.f1, 0xffbe), (.f12, 0xffc9)]
        for (k, v) in expected { #expect(k.keysym == v) }
        let fs: [SpecialKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
        for (i, k) in fs.enumerated() { #expect(k.keysym == 0xffbe + UInt32(i)) }
        #expect(KeyMapper.keystroke(for: .escape) == downUp(0xff1b))
    }

    @Test func modifiers() {
        #expect(ModifierKey.shift.keysym == 0xffe1)
        #expect(ModifierKey.control.keysym == 0xffe3)
        #expect(ModifierKey.option.keysym == 0xffe7)
        #expect(ModifierKey.command.keysym == 0xffeb)
    }

    @Test func keysymOnlyPassword() {
        let ev = KeyMapper.keystrokes(for: "aB1!", shiftStrategy: .keysymOnly)
        #expect(ev == downUp(0x61) + downUp(0x42) + downUp(0x31) + downUp(0x21))
        // Default strategy is keysymOnly.
        #expect(KeyMapper.keystrokes(for: "aB1!") == ev)
    }

    @Test func explicitShiftPassword() {
        let ev = KeyMapper.keystrokes(for: "aB1!", shiftStrategy: .explicitShift)
        #expect(ev == downUp(0x61) + [shiftDown] + downUp(0x42) + [shiftUp] + downUp(0x31) + [shiftDown] + downUp(0x21) + [shiftUp])
    }

    @Test func everyUSShiftedSymbolWrapped() {
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_+{}|:\"<>?" {
            #expect(KeyMapper.needsShift(ch), "\(ch)")
            let ev = KeyMapper.keystroke(for: ch, shiftStrategy: .explicitShift)
            #expect(ev.first == shiftDown && ev.last == shiftUp && ev.count == 4)
        }
        for ch in "abcxyz0123456789`-=[]\\;',./ " {
            #expect(!KeyMapper.needsShift(ch), "\(ch)")
            #expect(KeyMapper.keystroke(for: ch, shiftStrategy: .explicitShift).count == 2)
        }
    }

    @Test func balancedDownUpForArbitraryText() {
        let text = "Pässwörd #1 \u{e9}\u{301}中文😀\r\n\tend\u{0}"
        for strategy in [ShiftStrategy.keysymOnly, .explicitShift] {
            let ev = KeyMapper.keystrokes(for: text, shiftStrategy: strategy)
            var held: [UInt32: Int] = [:]
            for e in ev {
                held[e.keysym, default: 0] += e.down ? 1 : -1
                #expect(held[e.keysym]! >= 0 && held[e.keysym]! <= 1)
            }
            #expect(held.values.allSatisfy { $0 == 0 })
        }
    }

    @Test func decomposedCharactersAreComposed() {
        // "e" + combining acute → é (0xe9), one keypress.
        #expect(KeyMapper.keysyms(for: "e\u{301}") == [0xe9])
        // A character that cannot be composed sends each scalar.
        #expect(KeyMapper.keysyms(for: "q\u{301}") == [0x71, 0x0100_0301])
    }

    @Test func groupsDropUntypeable() {
        let g = KeyMapper.keystrokeGroups(for: "a\u{0}b")
        #expect(g == [downUp(0x61), downUp(0x62)])
        #expect(KeyMapper.keystrokes(for: "").isEmpty)
    }
}

@Suite struct ModifierLatchTests {
    @Test func cycle() {
        var l = ModifierLatch()
        #expect(l.state(of: .command) == .off)
        l.tap(.command); #expect(l.state(of: .command) == .oneShot)
        l.tap(.command); #expect(l.state(of: .command) == .locked)
        l.tap(.command); #expect(l.state(of: .command) == .off)
    }

    @Test func oneShotAppliesOnce() {
        var l = ModifierLatch()
        l.tap(.command)
        let c = KeyMapper.keystroke(for: "c")
        #expect(l.wrap(c) == [KeyEvent(keysym: 0xffeb, down: true)] + c + [KeyEvent(keysym: 0xffeb, down: false)])
        #expect(l.state(of: .command) == .off)
        #expect(l.wrap(c) == c)
    }

    @Test func lockedPersistsAndOrderIsStable() {
        var l = ModifierLatch()
        l.set(.shift, .locked)
        l.set(.command, .oneShot)
        l.set(.control, .oneShot)
        l.set(.option, .locked)
        #expect(l.active == [.control, .option, .shift, .command])
        let k = KeyMapper.keystroke(for: .left)
        let w = l.wrap(k)
        #expect(w == [KeyEvent(keysym: 0xffe3, down: true), KeyEvent(keysym: 0xffe7, down: true),
                      KeyEvent(keysym: 0xffe1, down: true), KeyEvent(keysym: 0xffeb, down: true)]
                + k +
                [KeyEvent(keysym: 0xffeb, down: false), KeyEvent(keysym: 0xffe1, down: false),
                 KeyEvent(keysym: 0xffe7, down: false), KeyEvent(keysym: 0xffe3, down: false)])
        #expect(l.active == [.option, .shift])
        _ = l.wrap(k)
        #expect(l.active == [.option, .shift])
        l.reset()
        #expect(l.active.isEmpty)
    }

    @Test func noDoubleShift() {
        var l = ModifierLatch()
        l.set(.shift, .oneShot)
        let k = KeyMapper.keystroke(for: "A", shiftStrategy: .explicitShift)
        #expect(l.wrap(k) == k)
        #expect(l.state(of: .shift) == .off)
    }

    @Test func emptyKeypressConsumesNothing() {
        var l = ModifierLatch()
        l.tap(.control)
        #expect(l.wrap([]).isEmpty)
        #expect(l.state(of: .control) == .oneShot)
    }
}
