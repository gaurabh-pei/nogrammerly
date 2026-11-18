import AppKit
import NogrammerlyCore

/// The Mac app's checker: Harper (bundled harper-ls) when it is available, otherwise the shared `WritingEngine`
/// with the system dictionary. It lives in the Mac target, not NogrammerlyCore, because Harper is a spawned
/// process that only exists on macOS; Core stays the same for the iOS app and keyboard.
enum MacWritingEngine {
    private static let appleSecondary = ProcessInfo.processInfo.environment["NOGRAMMERLY_APPLE_SECONDARY"] == "1"
        || UserDefaults.standard.bool(forKey: "NogrammerlyAppleSecondary")

    static func analyze(_ text: String) -> WritingAnalysis {
        analyze(text, harper: HarperEngine.shared)
    }

    /// `harper` nil means the Apple checker (NOGRAMMERLY_ENGINE=apple, or harper-ls not bundled). A lint that
    /// fails or is not ready also falls back to the Apple checker.
    static func analyze(_ text: String, harper: HarperEngine?) -> WritingAnalysis {
        guard let harper, let found = harper.lint(text) else { return WritingEngine.analyze(text) }
        // Harper is primary; the local phrase rules fill in what it does not cover ("utilize", "I think").
        // NOGRAMMERLY_APPLE_SECONDARY=1 also merges the Apple checker behind both.
        return WritingEngine.analyze(text, primary: preferAppleCorrections(found, in: text), systemChecker: appleSecondary)
    }

    /// Harper decides well what is misspelled, but Apple's checker usually picks the better word ("acess" → "access",
    /// not "ace's"; "wenesday" → "Wednesday", not "weekday"). For a Harper spelling finding that Apple also considers
    /// misspelled, use Apple's correction and keep Harper's as an alternative. Words Apple accepts keep Harper's fix.
    static func preferAppleCorrections(_ suggestions: [WritingSuggestion], in text: String) -> [WritingSuggestion] {
        let nsText = text as NSString
        return suggestions.map { suggestion in
            guard suggestion.isSpelling, suggestion.title.hasSuffix("(Harper)"), NSMaxRange(suggestion.range) <= nsText.length,
                  let apple = appleCorrection(for: suggestion.original),
                  apple != suggestion.original, apple != suggestion.replacement else { return suggestion }
            let message = suggestion.explanation.components(separatedBy: " Replace with ").first ?? suggestion.explanation
            return WritingSuggestion(kind: suggestion.kind, title: suggestion.title,
                                     explanation: HarperMapper.explanation(message, replacement: apple, alternatives: [suggestion.replacement].compactMap { $0 }),
                                     original: suggestion.original, replacement: apple, range: suggestion.range, isSpelling: true)
        }
    }

    private static let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    private static let correctionLock = NSLock()
    nonisolated(unsafe) private static var corrections: [String: String?] = [:]

    /// Apple's correction for a word it considers misspelled, or nil (also when it accepts the word). Cached per
    /// word and language, because every keystroke re-checks every misspelling in the field while Harper's own
    /// results come from its chunk cache; without this a 20,000-character field pays ~80 ms per keystroke.
    static func appleCorrection(for word: String) -> String? {
        let checker = NSSpellChecker.shared
        let key = checker.language() + "|" + word
        correctionLock.lock()
        if let cached = corrections[key] { correctionLock.unlock(); return cached }
        correctionLock.unlock()
        let range = NSRange(location: 0, length: (word as NSString).length)
        var answer: String?
        if checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound {
            answer = checker.correction(forWordRange: range, in: word, language: checker.language(), inSpellDocumentWithTag: spellTag)
                ?? checker.guesses(forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: spellTag)?.first
        }
        correctionLock.lock()
        if corrections.count > 4_000 { corrections.removeAll() }
        corrections[key] = .some(answer)
        correctionLock.unlock()
        return answer
    }
}
