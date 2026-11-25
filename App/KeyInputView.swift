import UIKit
import DuoVNCKit

/// Invisible responder that brings up the software keyboard and turns what it types into key events.
/// `hasText` is always true so Backspace keeps working on an "empty" field. Autocorrection, smart
/// quotes etc. are off so the Mac receives exactly the keys pressed.
///
/// With a hardware keyboard while this view is first responder, text still arrives via `insertText`;
/// keys that never produce text (arrows, Esc, F-keys, Home/End...) are caught in `pressesBegan`.
/// Shortcuts like ⌘C are only forwarded when the session view controller is first responder
/// (keyboard toggle off).
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    /// A non-text hardware key went down (true) or up (false).
    var onHardwareKey: ((UInt32, Bool) -> Void)?

    // UITextInputTraits
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    /// HID usages of keys that never produce text.
    private static let nonTextUsages: Set<Int> = {
        var s: Set<Int> = [0x29, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52]
        for u in 0x3A...0x45 { s.insert(u) }
        return s
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onBackspace?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled: Set<UIPress> = handle(presses, down: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled: Set<UIPress> = handle(presses, down: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled: Set<UIPress> = handle(presses, down: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func handle(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage: Int = key.keyCode.rawValue
            if KeyInputView.nonTextUsages.contains(usage), let keysym = HardwareKeyMap.keysym(forHIDUsage: usage) {
                onHardwareKey?(keysym, down)
            } else {
                unhandled.insert(press)
            }
        }
        return unhandled
    }
}
