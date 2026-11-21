import UIKit

enum KeyAction {
    case insert(String)
    case delete
    case shift
    case space
    case newline
    case page(KeyPage)
}

enum KeyPage { case letters, numbers, symbols }
enum ShiftState { case off, on, locked }

/// A standard QWERTY layout with number and symbol pages.
/// Colours are dynamic UIColors so the keys follow light/dark changes without a rebuild.
final class KeysView: UIView {
    var onAction: ((KeyAction) -> Void)?
    /// The globe key must be wired to `handleInputModeList(from:with:)` on the input view controller.
    weak var inputController: UIInputViewController?

    var page: KeyPage = .letters { didSet { if page != oldValue { rebuild() } } }
    var shift: ShiftState = .off { didSet { if shift != oldValue { rebuild() } } }
    var showsGlobe = false { didSet { if showsGlobe != oldValue { rebuild() } } }
    var returnTitle = "return" { didSet { if returnTitle != oldValue { rebuild() } } }

    private let rows = UIStackView()
    private var deleteTimer: Timer?

    static let letterKeyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    static let functionKeyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) }
    static let pressedKeyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.82, alpha: 1) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        rows.axis = .vertical
        rows.spacing = 10
        rows.distribution = .fillEqually
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var characterRows: [String] {
        switch page {
        case .letters: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .numbers: ["1234567890", "-/:;()$&@\"", ".,?!'"]
        case .symbols: ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]
        }
    }

    private func rebuild() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let characters = characterRows
        // Every character key has the width of a top-row key, so rows with fewer keys get centred.
        let top = characters[0].map { characterKey(String($0)) }
        let middle = characters[1].map { characterKey(String($0)) }
        let bottom = characters[2].map { characterKey(String($0)) }
        guard let reference = top.first else { return }
        let sameWidth = (middle + bottom + top.dropFirst()).map { $0.widthAnchor.constraint(equalTo: reference.widthAnchor) }

        rows.addArrangedSubview(row(top))
        rows.addArrangedSubview(row(middle.count < top.count ? [spacer()] + middle + [spacer()] : middle, equalSpacers: true))

        let modifier: UIButton = switch page {
        case .letters: functionKey(image: shift == .off ? "shift" : shift == .on ? "shift.fill" : "capslock.fill", label: "Shift") { [weak self] in self?.onAction?(.shift) }
        case .numbers: functionKey(title: "#+=") { [weak self] in self?.onAction?(.page(.symbols)) }
        case .symbols: functionKey(title: "123") { [weak self] in self?.onAction?(.page(.numbers)) }
        }
        let delete = functionKey(image: "delete.left", label: "Delete", action: nil)
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let sides = [modifier.widthAnchor.constraint(equalTo: reference.widthAnchor, multiplier: 1.4), delete.widthAnchor.constraint(equalTo: modifier.widthAnchor)]
        rows.addArrangedSubview(row([modifier, spacer()] + bottom + [spacer(), delete], equalSpacers: true))

        let pageKey = functionKey(title: page == .letters ? "123" : "ABC") { [weak self] in
            guard let self else { return }
            self.onAction?(.page(self.page == .letters ? .numbers : .letters))
        }
        var last: [UIView] = [pageKey]
        var widths = [pageKey.widthAnchor.constraint(equalTo: reference.widthAnchor, multiplier: 1.4)]
        if showsGlobe {
            let globe = functionKey(image: "globe", label: "Next keyboard", action: nil)
            globe.addTarget(inputController, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
            last.append(globe)
            widths.append(globe.widthAnchor.constraint(equalTo: pageKey.widthAnchor))
        }
        let space = key(title: "space", background: Self.letterKeyColor, font: .systemFont(ofSize: 16)) { [weak self] in self?.onAction?(.space) }
        space.accessibilityLabel = "Space"
        let enter = functionKey(title: returnTitle) { [weak self] in self?.onAction?(.newline) }
        widths.append(enter.widthAnchor.constraint(equalTo: reference.widthAnchor, multiplier: 2.4))
        last += [space, enter]
        rows.addArrangedSubview(row(last))

        NSLayoutConstraint.activate(sameWidth + sides + widths)
    }

    private func row(_ views: [UIView], equalSpacers: Bool = false) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fill
        if equalSpacers {
            let spacers = views.filter { $0.accessibilityIdentifier == "spacer" }
            if let first = spacers.first { spacers.dropFirst().forEach { $0.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true } }
        }
        return stack
    }

    private func spacer() -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = "spacer"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func characterKey(_ character: String) -> UIButton {
        let shown = page == .letters && shift != .off ? character.uppercased() : character
        return key(title: shown, background: Self.letterKeyColor, font: .systemFont(ofSize: 23)) { [weak self] in self?.onAction?(.insert(shown)) }
    }

    private func functionKey(title: String, action: @escaping () -> Void) -> UIButton {
        key(title: title, background: Self.functionKeyColor, font: .systemFont(ofSize: 16), action: action)
    }

    private func functionKey(image: String, label: String, action: (() -> Void)?) -> UIButton {
        let button = key(title: nil, background: Self.functionKeyColor, font: .systemFont(ofSize: 16), action: action)
        button.configuration?.image = UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        button.accessibilityLabel = label
        return button
    }

    private func key(title: String?, background: UIColor, font: UIFont, action: (() -> Void)?) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        configuration.background.cornerRadius = 6
        if let title {
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font]))
        }
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted ? Self.pressedKeyColor : background
        }
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        if let action { button.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        return button
    }

    @objc private func deleteDown() {
        onAction?(.delete)
        deleteTimer?.invalidate()
        // Hold to keep deleting: a short pause, then repeat.
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.onAction?(.delete) }
                }
            }
        }
    }

    @objc private func deleteUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }
}
