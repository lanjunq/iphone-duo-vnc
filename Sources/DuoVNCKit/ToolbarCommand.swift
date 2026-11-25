import Foundation

/// The session toolbar's buttons: visual order, size, and which ones go into the overflow menu first.
public enum ToolbarCommand: String, CaseIterable, Sendable {
    case click, rightClick, doubleClick, keyboard, password
    case escape, tab, returnKey
    case command, option, control, shift
    case left, up, down, right
    case zoom, more, disconnect

    /// Button title (Simplified Chinese or the key symbol).
    public var title: String {
        switch self {
        case .click: return "点击"
        case .rightClick: return "右键"
        case .doubleClick: return "双击"
        case .keyboard: return "键盘"
        case .password: return "密码"
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .returnKey: return "回车"
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .left: return "←"
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        case .zoom: return "缩放"
        case .more: return "更多"
        case .disconnect: return "断开"
        }
    }

    /// Lower = more important (hidden last).
    public var priority: Int {
        switch self {
        case .click: return 0
        case .rightClick: return 1
        case .keyboard: return 2
        case .password: return 3
        case .disconnect: return 4
        case .more: return 5
        case .doubleClick: return 6
        case .zoom: return 7
        case .escape: return 8
        case .returnKey: return 9
        case .tab: return 10
        case .command: return 11
        case .shift: return 12
        case .option: return 13
        case .control: return 14
        case .left: return 15
        case .right: return 16
        case .up: return 17
        case .down: return 18
        }
    }

    /// The click button is twice as long as the others.
    public var weight: Int { self == .click ? 2 : 1 }

    /// The modifier this button latches, if any.
    public var modifier: ModifierKey? {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        default: return nil
        }
    }

    /// The special key this button presses, if any.
    public var specialKey: SpecialKey? {
        switch self {
        case .escape: return .escape
        case .tab: return .tab
        case .returnKey: return .returnKey
        case .left: return .left
        case .up: return .up
        case .down: return .down
        case .right: return .right
        default: return nil
        }
    }

    /// `ToolbarLayout` items for all commands, in visual order.
    public static var layoutItems: [ToolbarLayout.Item] {
        allCases.map { ToolbarLayout.Item(id: $0.rawValue, weight: $0.weight, priority: $0.priority) }
    }
}
