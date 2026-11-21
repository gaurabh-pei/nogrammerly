import UIKit
import NogrammerlyCore

/// The Nogrammerly keyboard. It checks the text before the cursor (all a keyboard can see),
/// shows fixes above the keys, and rewrites with the on-device model. It never asks for Full Access,
/// so iOS keeps it off the network.
final class KeyboardViewController: UIInputViewController {
    /// Longest stretch of text checked at once; keeps checks quick and the model within its context window.
    private static let window = 1_000

    private let bar = SuggestionBar()
    private let keys = KeysView()
    private let rewritePanel = RewritePanel()

    private var shift: ShiftState = .on
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast

    /// The text the current suggestions refer to; always a suffix of the text before the cursor when they are valid.
    private var checked = ""
    private var suggestions: [WritingSuggestion] = []
    private var ignored: Set<String> = []
    private var checkTask: Task<Void, Never>?

    private var rewriteTarget: (range: NSRange, original: String, context: String)?
    private var rewriteResult: String?
    private var rewriteTone: WritingTone = .professional
    private var rewriteTask: Task<Void, Never>?

    private var before: String { textDocumentProxy.documentContextBeforeInput ?? "" }

    override func viewDidLoad() {
        super.viewDidLoad()
        keys.inputController = self
        keys.onAction = { [weak self] in self?.handle($0) }
        bar.onRewrite = { [weak self] in self?.openRewrite(for: nil) }
        bar.onTap = { [weak self] in self?.tapped($0) }
        bar.onIgnore = { [weak self] suggestion in
            guard let self else { return }
            self.ignored.insert(suggestion.ignoreKey)
            self.show(self.suggestions, for: self.checked)
        }
        rewritePanel.isHidden = true
        rewritePanel.onClose = { [weak self] in self?.closeRewrite() }
        rewritePanel.onRetry = { [weak self] in self?.generateRewrite() }
        rewritePanel.onTone = { [weak self] tone in self?.rewriteTone = tone; self?.generateRewrite() }
        rewritePanel.onAccept = { [weak self] in self?.acceptRewrite() }

        for view in [bar, keys, rewritePanel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        let height = view.heightAnchor.constraint(equalToConstant: 44 + 216)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            height,
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rewritePanel.topAnchor.constraint(equalTo: keys.topAnchor),
            rewritePanel.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            rewritePanel.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
            rewritePanel.bottomAnchor.constraint(equalTo: keys.bottomAnchor)
        ])
        AIWriter.prewarm()
    }

    override func viewWillLayoutSubviews() {
        keys.showsGlobe = needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncWithHost()
        scheduleCheck()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncWithHost()
        scheduleCheck()
    }

    /// Follows the host field's dark keyboard request, its return-key label and sentence capitalisation.
    private func syncWithHost() {
        let proxy = textDocumentProxy
        view.overrideUserInterfaceStyle = switch proxy.keyboardAppearance {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
        keys.returnTitle = switch proxy.returnKeyType {
        case .go: "go"
        case .search, .google, .yahoo: "search"
        case .send: "send"
        case .done: "done"
        case .next: "next"
        case .join: "join"
        default: "return"
        }
        updateAutoCapitalization()
    }

    // MARK: Typing

    private func handle(_ action: KeyAction) {
        let proxy = textDocumentProxy
        switch action {
        case .insert(let character):
            proxy.insertText(character)
            updateAutoCapitalization()
        case .delete:
            proxy.deleteBackward()
            updateAutoCapitalization()
        case .shift:
            let now = Date()
            if shift == .locked { setShift(.off) }
            else if now.timeIntervalSince(lastShiftTap) < 0.3 { setShift(.locked) }
            else { setShift(shift == .off ? .on : .off) }
            lastShiftTap = now
        case .space:
            let now = Date()
            let text = before
            // Double-tap space ends the sentence, as on the system keyboard.
            if now.timeIntervalSince(lastSpaceTap) < 0.35, text.hasSuffix(" "), let previous = text.dropLast().last, previous.isLetter || previous.isNumber {
                proxy.deleteBackward()
                proxy.insertText(". ")
                lastSpaceTap = .distantPast
            } else {
                proxy.insertText(" ")
                lastSpaceTap = now
            }
            if keys.page != .letters { keys.page = .letters }
            updateAutoCapitalization()
        case .newline:
            proxy.insertText("\n")
            updateAutoCapitalization()
        case .page(let page):
            keys.page = page
        }
        scheduleCheck()
    }

    private func setShift(_ state: ShiftState) {
        shift = state
        keys.shift = state
    }

    private func updateAutoCapitalization() {
        guard shift != .locked else { return }
        let text = before
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let startsWord = text.isEmpty || text.last?.isWhitespace == true
        let startsSentence = trimmed.isEmpty || text.hasSuffix("\n") || (text.hasSuffix(" ") && [".", "!", "?"].contains(trimmed.last.map(String.init) ?? ""))
        let capitalize = switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .allCharacters: true
        case .words: startsWord
        case .sentences: startsSentence
        default: false
        }
        setShift(capitalize ? .on : .off)
    }

    // MARK: Checking

    private func scheduleCheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let text = Self.checkWindow(of: self.before)
            let rules = WritingEngine.analyze(text).suggestions
            self.show(rules, for: text)
            guard AIWriter.isAvailable, text.contains(where: \.isLetter) else { return }
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled else { return }
            let found = await AIWriter.proofread(text)
            guard !Task.isCancelled, Self.checkWindow(of: self.before) == text, !found.isEmpty else { return }
            self.show(WritingEngine.merge(rules, found), for: text)
        }
    }

    /// The last `window` characters, starting at a word boundary.
    private static func checkWindow(of text: String) -> String {
        guard text.count > window else { return text }
        let tail = text.suffix(window)
        // Start at a word boundary when there is one; text without spaces (e.g. Japanese) is kept whole.
        guard tail.contains(where: \.isWhitespace) else { return String(tail) }
        return String(tail.drop { !$0.isWhitespace })
    }

    private func show(_ list: [WritingSuggestion], for text: String) {
        checked = text
        suggestions = list.filter { !ignored.contains($0.ignoreKey) && !Self.isWordInProgress($0, in: text) }
        guard rewritePanel.isHidden else { return }
        bar.show(suggestions, hasText: text.contains(where: \.isLetter))
    }

    /// A word that touches the cursor may still be being typed, so it isn't flagged yet.
    private static func isWordInProgress(_ suggestion: WritingSuggestion, in text: String) -> Bool {
        NSMaxRange(suggestion.range) == (text as NSString).length && (text.last?.isLetter ?? false)
    }

    private func tapped(_ suggestion: WritingSuggestion) {
        guard let replacement = suggestion.replacement else { openRewrite(for: suggestion); return }
        guard before.hasSuffix(checked),
              let edit = ContextEdit.replacing(suggestion.range, in: checked, expected: suggestion.original, with: replacement) else { scheduleCheck(); return }
        perform(edit)
    }

    private func perform(_ edit: ContextEdit) {
        for _ in 0..<edit.deleteCount { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(edit.insert)
        scheduleCheck()
    }

    // MARK: Rewriting

    /// Rewrites the sentence holding `suggestion`, or everything before the cursor when nil.
    private func openRewrite(for suggestion: WritingSuggestion?) {
        // A suggestion's range refers to `checked`; if the text has changed since, re-check instead.
        if suggestion != nil, !before.hasSuffix(checked) { scheduleCheck(); return }
        let context = suggestion == nil ? Self.checkWindow(of: before) : checked
        guard context.contains(where: \.isLetter) else { return }
        let range = suggestion.map { WritingEngine.sentenceRange(containing: $0.range, in: context) }
            ?? NSRange(location: 0, length: (context as NSString).length)
        rewriteTarget = (range, (context as NSString).substring(with: range), context)
        rewritePanel.isHidden = false
        keys.isHidden = true
        bar.showStatus(suggestion == nil ? "Rewrite what you've typed" : "Rewrite this sentence")
        generateRewrite()
    }

    private func generateRewrite() {
        guard let target = rewriteTarget else { return }
        let tone = rewriteTone
        rewriteResult = nil
        rewritePanel.showLoading(tone: tone)
        rewriteTask?.cancel()
        rewriteTask = Task { [weak self] in
            let result = await AIWriter.rewrite(target.original, tone: tone) ?? WritingEngine.rewrite(target.original, tone: tone)
            guard let self, !Task.isCancelled else { return }
            self.rewriteResult = result
            self.rewritePanel.showResult(result)
        }
    }

    private func acceptRewrite() {
        guard let target = rewriteTarget, let result = rewriteResult else { return }
        if before.hasSuffix(target.context),
           let edit = ContextEdit.replacing(target.range, in: target.context, expected: target.original, with: result) {
            perform(edit)
        }
        closeRewrite()
    }

    private func closeRewrite() {
        rewriteTask?.cancel()
        rewriteTarget = nil
        rewriteResult = nil
        rewritePanel.isHidden = true
        keys.isHidden = false
        show(suggestions, for: checked)
        scheduleCheck()
    }
}
