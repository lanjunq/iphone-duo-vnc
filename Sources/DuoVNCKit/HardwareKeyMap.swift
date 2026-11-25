import Foundation

/// Hardware keyboard (USB HID usage page 7, as in `UIKeyboardHIDUsage`) → X11 keysyms.
/// The app forwards modifier presses as their own key events, so a character key maps to one keysym.
public enum HardwareKeyMap {
    /// Keysym for a non-character key or a modifier, by HID usage; nil for character keys (letters,
    /// digits, punctuation), which go through `characterKeysyms`, and for keys we do not forward
    /// (Caps Lock, media keys...). Right-hand modifiers map to the left-hand keysyms the app uses.
    public static func keysym(forHIDUsage usage: Int) -> UInt32? {
        switch usage {
        case 0x28, 0x58: return SpecialKey.returnKey.keysym   // Return, keypad Enter
        case 0x29: return SpecialKey.escape.keysym
        case 0x2A: return SpecialKey.backspace.keysym
        case 0x2B: return SpecialKey.tab.keysym
        case 0x2C: return SpecialKey.space.keysym
        case 0x3A...0x45:                                      // F1...F12
            return SpecialKey.f1.keysym + UInt32(usage - 0x3A)
        case 0x49: return 0xff63                               // Insert
        case 0x4A: return SpecialKey.home.keysym
        case 0x4B: return SpecialKey.pageUp.keysym
        case 0x4C: return SpecialKey.forwardDelete.keysym
        case 0x4D: return SpecialKey.end.keysym
        case 0x4E: return SpecialKey.pageDown.keysym
        case 0x4F: return SpecialKey.right.keysym
        case 0x50: return SpecialKey.left.keysym
        case 0x51: return SpecialKey.down.keysym
        case 0x52: return SpecialKey.up.keysym
        case 0xE0, 0xE4: return ModifierKey.control.keysym
        case 0xE1, 0xE5: return ModifierKey.shift.keysym
        case 0xE2, 0xE6: return ModifierKey.option.keysym
        case 0xE3, 0xE7: return ModifierKey.command.keysym
        default: return nil
        }
    }

    /// True for the eight modifier usages (0xE0...0xE7).
    public static func isModifier(usage: Int) -> Bool { (0xE0...0xE7).contains(usage) }

    /// Keysyms for a character key. With ⌘, ⌃ or ⌥ held, the unmodified character is used (⌘C must send
    /// "c", not what the layout would produce with Option); otherwise the produced characters (which
    /// already include Shift, e.g. "A"). Empty when nothing is typeable (e.g. a dead key).
    public static func characterKeysyms(characters: String, charactersIgnoringModifiers: String,
                                        commandControlOrOptionHeld: Bool) -> [UInt32] {
        let source = commandControlOrOptionHeld ? charactersIgnoringModifiers : characters
        guard let ch = source.first, source.count == 1 else {
            if !commandControlOrOptionHeld, characters.isEmpty, let c = charactersIgnoringModifiers.first,
               charactersIgnoringModifiers.count == 1 {
                return KeyMapper.keysyms(for: c)
            }
            return source.isEmpty ? [] : source.flatMap { KeyMapper.keysyms(for: $0) }
        }
        return KeyMapper.keysyms(for: ch)
    }
}
