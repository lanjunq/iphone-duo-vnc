import UIKit
import DuoVNCKit

/// The session toolbar. Buttons are placed by `ToolbarLayout` (pure, tested in DuoVNCKit) for the
/// frame, axis and fold keep-out rects that `LayoutEngine` computed; buttons that do not fit are
/// reported through `onOverflowChanged` so the 更多 menu can offer them.
final class SessionToolbarView: UIView {
    /// A command button was tapped (not called for 更多, which opens its menu).
    var onCommand: ((ToolbarCommand) -> Void)?
    /// The set of hidden commands changed (visual order).
    var onOverflowChanged: (([ToolbarCommand]) -> Void)?

    private var buttons: [ToolbarCommand: UIButton] = [:]
    private var axis: LayoutEngine.ToolbarAxis = .bottom
    /// Keep-out rects in this view's coordinates.
    private var keepOut: [CGRect] = []
    private var overflowCommands: [ToolbarCommand] = []
    private var latch: ModifierLatch = ModifierLatch()
    private var zoomedIn: Bool = false
    private var keyboardShown: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        for command in ToolbarCommand.allCases {
            let button: UIButton = UIButton(type: .custom)
            button.setTitle(command.title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
            button.titleLabel?.font = command == .click
                ? UIFont.systemFont(ofSize: 20, weight: .bold)
                : UIFont.systemFont(ofSize: 17, weight: .medium)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.6
            button.layer.cornerRadius = 10
            button.tag = ToolbarCommand.allCases.firstIndex(of: command) ?? 0
            button.accessibilityLabel = command.title
            if command == .more {
                button.showsMenuAsPrimaryAction = true
            } else {
                button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            }
            buttons[command] = button
            addSubview(button)
        }
        refreshAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Axis and keep-out rects (already converted into this view's coordinates).
    func configure(axis: LayoutEngine.ToolbarAxis, keepOut: [CGRect]) {
        if self.axis != axis || self.keepOut != keepOut {
            self.axis = axis
            self.keepOut = keepOut
            setNeedsLayout()
        }
    }

    /// The menu of the 更多 button.
    func setMoreMenu(_ menu: UIMenu) {
        buttons[.more]?.menu = menu
    }

    func setModifiers(_ latch: ModifierLatch) {
        self.latch = latch
        refreshAppearance()
    }

    func setZoomedIn(_ zoomed: Bool) {
        zoomedIn = zoomed
        buttons[.zoom]?.setTitle(zoomed ? "全屏" : "放大", for: .normal)
    }

    func setKeyboardShown(_ shown: Bool) {
        keyboardShown = shown
        refreshAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let placement: ToolbarLayout.Placement = ToolbarLayout.layout(items: ToolbarCommand.layoutItems, in: bounds,
                                                                      axis: axis, keepOut: keepOut)
        for (command, button) in buttons {
            if let frame = placement.frames[command.rawValue] {
                button.isHidden = false
                button.frame = frame
            } else {
                button.isHidden = true
            }
        }
        let newHidden: [ToolbarCommand] = placement.hidden.compactMap { ToolbarCommand(rawValue: $0) }
        if newHidden != overflowCommands {
            overflowCommands = newHidden
            onOverflowChanged?(newHidden)
        }
    }

    private func refreshAppearance() {
        for (command, button) in buttons {
            var color: UIColor = UIColor(white: 0.24, alpha: 1)
            if command == .click {
                color = UIColor.systemBlue
            } else if command == .disconnect {
                color = UIColor(red: 0.55, green: 0.12, blue: 0.12, alpha: 1)
            } else if command == .keyboard && keyboardShown {
                color = UIColor.systemTeal
            } else if let modifier = command.modifier {
                switch latch.state(of: modifier) {
                case .off:
                    color = UIColor(white: 0.24, alpha: 1)
                case .oneShot:
                    color = UIColor.systemOrange.withAlphaComponent(0.55)
                case .locked:
                    color = UIColor.systemOrange
                }
            }
            button.backgroundColor = color
            if let modifier = command.modifier {
                // Locked modifiers get an underline-like border so the two latched states differ by shape too.
                button.layer.borderWidth = latch.state(of: modifier) == .locked ? 2 : 0
                button.layer.borderColor = UIColor.white.cgColor
            }
        }
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        let all: [ToolbarCommand] = ToolbarCommand.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        onCommand?(all[sender.tag])
    }
}
