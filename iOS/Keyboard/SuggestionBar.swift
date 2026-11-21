import UIKit
import NogrammerlyCore

/// The strip above the keys: a ✦ rewrite button, then one chip per suggestion.
final class SuggestionBar: UIView {
    var onRewrite: (() -> Void)?
    var onTap: ((WritingSuggestion) -> Void)?
    var onIgnore: ((WritingSuggestion) -> Void)?

    private let rewriteButton = UIButton(configuration: .plain())
    private let scroll = UIScrollView()
    private let chips = UIStackView()
    private let status = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "sparkles")
        configuration.baseForegroundColor = .systemIndigo
        rewriteButton.configuration = configuration
        rewriteButton.accessibilityLabel = "Rewrite"
        rewriteButton.addAction(UIAction { [weak self] _ in self?.onRewrite?() }, for: .touchUpInside)

        status.font = .systemFont(ofSize: 14)
        status.textColor = .secondaryLabel

        chips.axis = .horizontal
        chips.spacing = 8
        chips.alignment = .center
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(chips)
        chips.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [rewriteButton, status, scroll])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rewriteButton.widthAnchor.constraint(equalToConstant: 40),
            chips.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        show([], hasText: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ suggestions: [WritingSuggestion], hasText: Bool) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestions.forEach { chips.addArrangedSubview(chip(for: $0)) }
        scroll.isHidden = suggestions.isEmpty
        status.isHidden = !suggestions.isEmpty
        status.text = hasText ? "Looks good" : "Nogrammerly"
        rewriteButton.isEnabled = hasText
        scroll.contentOffset = .zero
    }

    /// Shown instead of the chips while the rewrite panel is open.
    func showStatus(_ text: String) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scroll.isHidden = true
        status.isHidden = false
        status.text = text
    }

    private func chip(for suggestion: WritingSuggestion) -> ChipButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = suggestion.kind.color.withAlphaComponent(0.15)
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        configuration.image = UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 7))
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in suggestion.kind.color }
        configuration.imagePadding = 6
        let text = suggestion.replacement.map { "\(suggestion.original) → \($0)" } ?? "\(suggestion.original): \(suggestion.title)"
        configuration.attributedTitle = AttributedString(text, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .medium)]))
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = ChipButton(chip: configuration)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        button.accessibilityLabel = suggestion.replacement.map { "Change \(suggestion.original) to \($0)" } ?? "\(suggestion.title): \(suggestion.original). Opens rewrite."
        button.accessibilityHint = "Press and hold to ignore."
        button.addAction(UIAction { [weak self] _ in self?.onTap?(suggestion) }, for: .touchUpInside)
        button.onHold = { [weak self] in self?.onIgnore?(suggestion) }
        return button
    }
}

/// A chip that also reports a press-and-hold (UIButton has no long-press event).
private final class ChipButton: UIButton {
    var onHold: (() -> Void)?

    convenience init(chip configuration: UIButton.Configuration) {
        self.init(type: .system)
        self.configuration = configuration
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onHold?() }
    }
}
