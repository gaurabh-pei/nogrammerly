import UIKit
import NogrammerlyCore

/// Takes the place of the keys while a rewrite is generated and reviewed.
final class RewritePanel: UIView {
    var onTone: ((WritingTone) -> Void)?
    var onRetry: (() -> Void)?
    var onAccept: (() -> Void)?
    var onClose: (() -> Void)?

    private let tones = UISegmentedControl(items: WritingTone.allCases.map(\.rawValue))
    private let text = UITextView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let accept = UIButton(configuration: .borderedProminent())
    private let retry = UIButton(configuration: .bordered())

    override init(frame: CGRect) {
        super.init(frame: frame)
        tones.selectedSegmentIndex = 0
        tones.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onTone?(WritingTone.allCases[max(0, self.tones.selectedSegmentIndex)])
        }, for: .valueChanged)

        text.isEditable = false
        text.font = .systemFont(ofSize: 15)
        text.textColor = .label
        text.backgroundColor = .secondarySystemBackground
        text.layer.cornerRadius = 8
        text.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        spinner.hidesWhenStopped = true

        var close = UIButton.Configuration.bordered()
        close.image = UIImage(systemName: "keyboard")
        let closeButton = UIButton(configuration: close)
        closeButton.accessibilityLabel = "Back to keyboard"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        retry.configuration?.image = UIImage(systemName: "arrow.clockwise")
        retry.accessibilityLabel = "Try again"
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        accept.configuration?.title = "Replace"
        accept.configuration?.baseBackgroundColor = .systemIndigo
        accept.addAction(UIAction { [weak self] _ in self?.onAccept?() }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [closeButton, retry, UIView(), accept])
        buttons.spacing = 8
        let stack = UIStackView(arrangedSubviews: [tones, text, buttons])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            spinner.centerXAnchor.constraint(equalTo: text.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: text.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showLoading(tone: WritingTone) {
        tones.selectedSegmentIndex = WritingTone.allCases.firstIndex(of: tone) ?? 0
        text.text = ""
        spinner.startAnimating()
        accept.isEnabled = false
        retry.isEnabled = false
    }

    func showResult(_ result: String) {
        spinner.stopAnimating()
        text.text = result
        text.setContentOffset(.zero, animated: false)
        accept.isEnabled = true
        retry.isEnabled = true
    }
}
