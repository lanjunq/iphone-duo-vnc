import UIKit
import DuoVNCSession

/// Connection status over the desktop: spinner + text, and 重试 / 返回 buttons when it gave up.
final class ConnectionHUDView: UIView {
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    private let spinner: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
    private let label: UILabel = UILabel()
    private let retryButton: UIButton = UIButton(type: .system)
    private let closeButton: UIButton = UIButton(type: .system)
    private let buttonRow: UIStackView = UIStackView()
    private let stack: UIStackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 0.86)
        layer.cornerRadius = 14
        isUserInteractionEnabled = true

        spinner.color = .white
        spinner.hidesWhenStopped = true
        label.textColor = .white
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        label.textAlignment = .center

        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        retryButton.addTarget(self, action: #selector(retryTapped(_:)), for: .touchUpInside)
        closeButton.setTitle("返回", for: .normal)
        closeButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        closeButton.addTarget(self, action: #selector(closeTapped(_:)), for: .touchUpInside)

        buttonRow.axis = .horizontal
        buttonRow.spacing = 28
        buttonRow.addArrangedSubview(retryButton)
        buttonRow.addArrangedSubview(closeButton)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(buttonRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the state; hides itself when there is nothing to say.
    func show(_ state: SessionState) {
        guard let text = state.hudText else {
            isHidden = true
            spinner.stopAnimating()
            return
        }
        isHidden = false
        label.text = text
        if state.isBusy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        var showRetry: Bool = false
        switch state {
        case .failed, .waitingToReconnect, .suspended:
            showRetry = true
        default:
            showRetry = false
        }
        retryButton.isHidden = !showRetry
        // "返回" is useful whenever the session is not working.
        buttonRow.isHidden = false
    }

    @objc private func retryTapped(_ sender: UIButton) {
        onRetry?()
    }

    @objc private func closeTapped(_ sender: UIButton) {
        onClose?()
    }
}
