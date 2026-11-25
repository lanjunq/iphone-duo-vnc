import Foundation

/// One RFB KeyEvent.
public struct KeyEvent: Equatable, Hashable, Sendable {
    /// X11 keysym.
    public var keysym: UInt32
    public var down: Bool
    public init(keysym: UInt32, down: Bool) {
        self.keysym = keysym
        self.down = down
    }
}

/// Non-character keys, with their X11 keysyms.
public enum SpecialKey: CaseIterable, Equatable, Hashable, Sendable {
    case returnKey, tab, escape, backspace, forwardDelete
    case left, up, right, down
    case home, end, pageUp, pageDown
    case space
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var keysym: UInt32 {
        switch self {
        case .returnKey: return 0xff0d
        case .tab: return 0xff09
        case .escape: return 0xff1b
        case .backspace: return 0xff08
        case .forwardDelete: return 0xffff
        case .left: return 0xff51
        case .up: return 0xff52
        case .right: return 0xff53
        case .down: return 0xff54
        case .home: return 0xff50
        case .end: return 0xff57
        case .pageUp: return 0xff55
        case .pageDown: return 0xff56
        case .space: return 0x0020
        case .f1: return 0xffbe
        case .f2: return 0xffbf
        case .f3: return 0xffc0
        case .f4: return 0xffc1
        case .f5: return 0xffc2
        case .f6: return 0xffc3
        case .f7: return 0xffc4
        case .f8: return 0xffc5
        case .f9: return 0xffc6
        case .f10: return 0xffc7
        case .f11: return 0xffc8
        case .f12: return 0xffc9
        }
    }
}

/// Modifier keys, with the keysyms the Mac server expects (left-hand variants).
public enum ModifierKey: CaseIterable, Equatable, Hashable, Sendable {
    case shift, control, option, command

    /// Measured against macOS 27.0.1 Screen Sharing (2026-11-24): Command = Super_L 0xffeb (Alt_L
    /// 0xffe9 also acts as Command), Option = Meta_L 0xffe7, Control = Control_L 0xffe3,
    /// Shift = Shift_L 0xffe1. This is NOT the usual X11 reading of Alt/Meta.
    public var keysym: UInt32 {
        switch self {
        case .shift: return 0xffe1
        case .control: return 0xffe3
        case .option: return 0xffe7
        case .command: return 0xffeb
        }
    }
}

/// How to send characters that need Shift on a US keyboard.
public enum ShiftStrategy: Equatable, Sendable {
    /// Send only the character's keysym (e.g. `A` = 0x41); the server works out Shift.
    case keysymOnly
    /// Wrap such characters in Shift_L down/up.
    case explicitShift
}

/// Text and keys → X11 keysyms / KeyEvents.
public enum KeyMapper {
    /// Characters that need Shift on a US ANSI layout.
    static let usShifted: Set<Unicode.Scalar> = {
        var s = Set<Unicode.Scalar>()
        for v in UInt32(0x41)...UInt32(0x5a) { s.insert(Unicode.Scalar(v)!) }   // A-Z
        for c in "~!@#$%^&*()_+{}|:\"<>?".unicodeScalars { s.insert(c) }
        return s
    }()

    /// Keysym for one Unicode scalar:
    /// - `\n`, `\r` → Return; `\t` → Tab; backspace (0x08) → BackSpace; escape (0x1b) → Escape;
    /// - printable Latin-1 (0x20–0x7e, 0xa0–0xff) → the code point itself;
    /// - other C0/C1 control characters and DEL → nil (not typeable);
    /// - anything else → `0x01000000 + scalar`.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32? {
        let v = scalar.value
        switch v {
        case 0x0a, 0x0d: return SpecialKey.returnKey.keysym
        case 0x09: return SpecialKey.tab.keysym
        case 0x08: return SpecialKey.backspace.keysym
        case 0x1b: return SpecialKey.escape.keysym
        case 0x20...0x7e, 0xa0...0xff: return v
        case 0x00...0x1f, 0x7f...0x9f: return nil
        default: return 0x0100_0000 + v
        }
    }

    /// Keysyms for one Character (grapheme). `\r\n` is a single Return. A character made of several
    /// scalars (after NFC composition) yields one keysym per scalar. Unmappable scalars are skipped.
    public static func keysyms(for character: Character) -> [UInt32] {
        if character == "\r\n" { return [SpecialKey.returnKey.keysym] }
        let composed = String(character).precomposedStringWithCanonicalMapping
        return composed.unicodeScalars.compactMap { keysym(for: $0) }
    }

    /// Whether the character needs Shift on a US layout.
    public static func needsShift(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let s = scalars.first else { return false }
        return usShifted.contains(s)
    }

    /// Key events for one character, grouped so a caller can wrap each keypress (e.g. with latched
    /// modifiers). Empty when nothing in the character is typeable.
    public static func keystroke(for character: Character, shiftStrategy: ShiftStrategy = .keysymOnly) -> [KeyEvent] {
        let syms = keysyms(for: character)
        guard !syms.isEmpty else { return [] }
        var out: [KeyEvent] = []
        let wrap = shiftStrategy == .explicitShift && needsShift(character)
        if wrap { out.append(KeyEvent(keysym: ModifierKey.shift.keysym, down: true)) }
        for k in syms {
            out.append(KeyEvent(keysym: k, down: true))
            out.append(KeyEvent(keysym: k, down: false))
        }
        if wrap { out.append(KeyEvent(keysym: ModifierKey.shift.keysym, down: false)) }
        return out
    }

    /// Ordered key down/up events for typing `text`, one keypress group per character, flattened.
    public static func keystrokes(for text: String, shiftStrategy: ShiftStrategy = .keysymOnly) -> [KeyEvent] {
        keystrokeGroups(for: text, shiftStrategy: shiftStrategy).flatMap { $0 }
    }

    /// Like `keystrokes(for:shiftStrategy:)` but one array per typed character (empty groups dropped).
    public static func keystrokeGroups(for text: String, shiftStrategy: ShiftStrategy = .keysymOnly) -> [[KeyEvent]] {
        text.compactMap { ch -> [KeyEvent]? in
            let g = keystroke(for: ch, shiftStrategy: shiftStrategy)
            return g.isEmpty ? nil : g
        }
    }

    /// Down + up for a special key.
    public static func keystroke(for key: SpecialKey) -> [KeyEvent] {
        [KeyEvent(keysym: key.keysym, down: true), KeyEvent(keysym: key.keysym, down: false)]
    }
}
