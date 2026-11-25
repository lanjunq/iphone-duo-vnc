import UIKit

/// Sheet for typing a password or a one-time code into the Mac.
///
/// The text stays in a secure `UITextField` (password AutoFill works) until the user taps 发送; it is
/// then sent as key events through `onSend` and the field is cleared. It is never logged, never
/// stored, and never put on the remote or local clipboard. The field is also cleared whenever the
/// sheet goes away.
final class SecureEntryViewController: UIViewController, UITextFieldDelegate {
    /// Sends the text; `pressReturn` appends a Return key. Returns false if nothing was sent
    /// (not connected), in which case the sheet stays open and the text is kept.
    var onSend: ((String, Bool) -> Bool)?
    var onDismiss: (() -> Void)?

    private let modeControl: UISegmentedControl = UISegmentedControl(items: ["密码", "验证码"])
    private let field: UITextField = UITextField()
    private let hintLabel: UILabel = UILabel()
    private let sendButton: UIButton = UIButton(type: .system)
    private let sendReturnButton: UIButton = UIButton(type: .system)
    private let cancelButton: UIButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        let title: UILabel = UILabel()
        title.text = "输入到 Mac"
        title.font = UIFont.preferredFont(forTextStyle: .headline)

        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)

        field.borderStyle = .roundedRect
        field.font = UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .go
        field.delegate = self
        applyMode()

        hintLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = UIColor.secondaryLabel
        hintLabel.numberOfLines = 0
        hintLabel.text = "先在 Mac 上点中输入框。内容只会作为按键发送，不会经过剪贴板，也不会被保存。"

        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        sendButton.addTarget(self, action: #selector(sendTapped(_:)), for: .touchUpInside)
        sendReturnButton.setTitle("发送并回车", for: .normal)
        sendReturnButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        sendReturnButton.addTarget(self, action: #selector(sendReturnTapped(_:)), for: .touchUpInside)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped(_:)), for: .touchUpInside)

        let buttons: UIStackView = UIStackView(arrangedSubviews: [cancelButton, sendButton, sendReturnButton])
        buttons.axis = .horizontal
        buttons.distribution = .equalSpacing

        let stack: UIStackView = UIStackView(arrangedSubviews: [title, modeControl, field, hintLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide: UILayoutGuide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    // Not cleared in viewWillDisappear: a swipe-down the user takes back would wipe the typed text.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        field.text = ""
        // Only a real dismissal hands focus back (not something presented over the sheet).
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?()
            onDismiss = nil
        }
    }

    private func applyMode() {
        let otp: Bool = modeControl.selectedSegmentIndex == 1
        field.text = ""
        field.isSecureTextEntry = !otp
        field.textContentType = otp ? UITextContentType.oneTimeCode : UITextContentType.password
        field.keyboardType = otp ? UIKeyboardType.asciiCapableNumberPad : UIKeyboardType.asciiCapable
        field.placeholder = otp ? "验证码" : "密码"
        if field.isFirstResponder {
            field.reloadInputViews()
        }
    }

    @objc private func modeChanged(_ sender: UISegmentedControl) {
        applyMode()
    }

    @objc private func sendTapped(_ sender: UIButton) {
        send(pressReturn: false)
    }

    @objc private func sendReturnTapped(_ sender: UIButton) {
        send(pressReturn: true)
    }

    @objc private func cancelTapped(_ sender: UIButton) {
        field.text = ""
        dismiss(animated: true, completion: nil)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send(pressReturn: true)
        return false
    }

    private func send(pressReturn: Bool) {
        let text: String = field.text ?? ""
        guard !text.isEmpty || pressReturn else { return }
        let sent: Bool = onSend?(text, pressReturn) ?? false
        if sent {
            field.text = ""
            dismiss(animated: true, completion: nil)
        } else {
            hintLabel.text = "还没连上 Mac，没有发送。连上后再点发送。"
            hintLabel.textColor = UIColor.systemOrange
        }
    }
}
