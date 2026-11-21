import Foundation
import Observation
import NogrammerlyCore

/// The in-app document: instant rule checks on every edit, then on-device AI checks once typing pauses.
@MainActor @Observable
final class EditorModel {
    static let sample = "Hello team,\n\nI wanted to recieve your feedback on the proposal. We utilize the new workflow in order to make our approvals faster, and I think it will be very helpful!!\n\nThank you"
    private static let storageKey = "document"

    var text: String {
        didSet {
            guard text != oldValue else { return }
            UserDefaults.standard.set(text, forKey: Self.storageKey)
            refresh()
        }
    }
    var tone: WritingTone = .professional
    private(set) var suggestions: [WritingSuggestion] = []
    private(set) var analysis = WritingAnalysis(suggestions: [], words: 0, readability: 100, tone: "Neutral")
    private(set) var isRewriting = false
    /// Set when a rewrite is ready to review; nil hides the preview.
    var rewrite: Rewrite?
    var message: String?

    struct Rewrite: Identifiable {
        let id = UUID()
        let original: String
        let rewritten: String
        let tone: WritingTone
    }

    private var ignored: Set<String> = []
    private var proofreadTask: Task<Void, Never>?

    init() {
        text = UserDefaults.standard.string(forKey: Self.storageKey) ?? Self.sample
        refresh()
    }

    func refresh() {
        let current = text
        let result = WritingEngine.analyze(current)
        analysis = result
        show(result.suggestions)
        proofreadTask?.cancel()
        proofreadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            let found = await AIWriter.proofread(current)
            guard let self, !Task.isCancelled, self.text == current, !found.isEmpty else { return }
            self.show(WritingEngine.merge(result.suggestions, found))
        }
    }

    private func show(_ list: [WritingSuggestion]) {
        suggestions = list.filter { !ignored.contains($0.ignoreKey) }
    }

    /// Applies a suggestion only if the text it refers to is still there.
    func apply(_ suggestion: WritingSuggestion) {
        let nsText = text as NSString
        guard let replacement = suggestion.replacement, NSMaxRange(suggestion.range) <= nsText.length,
              nsText.substring(with: suggestion.range) == suggestion.original else { refresh(); return }
        text = nsText.replacingCharacters(in: suggestion.range, with: replacement)
    }

    func ignore(_ suggestion: WritingSuggestion) {
        ignored.insert(suggestion.ignoreKey)
        suggestions.removeAll { $0.ignoreKey == suggestion.ignoreKey }
    }

    func startRewrite() {
        let original = text, tone = tone
        guard original.contains(where: \.isLetter), !isRewriting else { return }
        isRewriting = true
        Task { [weak self] in
            let rewritten = await AIWriter.rewrite(original, tone: tone) ?? WritingEngine.rewrite(original, tone: tone)
            guard let self else { return }
            self.isRewriting = false
            guard self.text == original else { self.message = "The text changed while rewriting, so the rewrite was discarded."; return }
            self.rewrite = Rewrite(original: original, rewritten: rewritten, tone: tone)
        }
    }

    func accept(_ rewrite: Rewrite) {
        guard text == rewrite.original else { message = "The text changed, so the rewrite was not applied."; return }
        text = rewrite.rewritten
        self.rewrite = nil
    }

    func clear() { text = "" }
}
