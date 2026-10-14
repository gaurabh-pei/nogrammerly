import AppKit

/// Fast, synchronous checks: the macOS spelling/grammar checker plus local style rules.
/// Deeper grammar, clarity and tone checks come asynchronously from `AIWriter`.
enum WritingEngine {
    /// Fields longer than this are skipped to keep system-wide polling cheap.
    static let maxLength = 20_000
    static let spellTag = NSSpellChecker.uniqueSpellDocumentTag()

    private static let styleRules: [(phrase: String, replacement: String?, title: String, kind: SuggestionKind)] = [
        ("utilize", "use", "Prefer simpler wording", .clarity),
        ("utilise", "use", "Prefer simpler wording", .clarity),
        ("in order to", "to", "Make this more concise", .clarity),
        ("due to the fact that", "because", "Make this more concise", .clarity),
        ("at this point in time", "now", "Make this more concise", .clarity),
        ("in the event that", "if", "Make this more concise", .clarity),
        ("very", nil, "Consider a more precise word", .style),
        ("really", nil, "Consider a more precise word", .style),
        ("just", nil, "This may weaken your message", .delivery),
        ("I think", nil, "Sound more confident", .delivery),
        ("sorry to bother you", nil, "This may undercut your request", .delivery)
    ]

    static func analyze(_ text: String) -> WritingAnalysis {
        let nsText = text as NSString
        var suggestions: [WritingSuggestion] = []
        for rule in styleRules {
            for range in wordRanges(of: rule.phrase, in: text) {
                let original = nsText.substring(with: range)
                let replacement = rule.replacement.map { matchCase(of: original, $0) }
                suggestions.append(WritingSuggestion(kind: rule.kind, title: rule.title, explanation: replacement.map { "Replace “\(original)” with “\($0)”." } ?? "“\(original)” can make the sentence less direct.", original: original, replacement: replacement, range: range))
            }
        }
        for match in matches(of: " {2,}", in: text) {
            suggestions.append(WritingSuggestion(kind: .correctness, title: "Extra space", explanation: "Use one space between words.", original: nsText.substring(with: match), replacement: " ", range: match))
        }
        var sentenceCount = 0
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .bySentences) { sentence, range, _, _ in
            guard let sentence else { return }
            sentenceCount += 1
            let count = sentence.split(whereSeparator: \.isWhitespace).count
            if count > 28 {
                suggestions.append(WritingSuggestion(kind: .clarity, title: "Long sentence", explanation: "This sentence has \(count) words. Consider splitting it.", original: sentence, replacement: nil, range: range))
            }
        }
        for match in matches(of: "!{2,}", in: text) {
            suggestions.append(WritingSuggestion(kind: .delivery, title: "Repeated exclamation marks", explanation: "One exclamation mark is enough, if any.", original: nsText.substring(with: match), replacement: "!", range: match))
        }

        let words = text.split { $0.isWhitespace }.count
        let avg = words / max(sentenceCount, 1)
        // Specific phrase rules win over the dictionary where they overlap (e.g. "utilize" → "use", not "utilise").
        let unique = merge(suggestions, checkSpellingAndGrammar(text))
        let readability = max(35, min(100, 100 - max(avg - 12, 0) * 3 - unique.count * 2))
        let tone = text.contains("!") ? "Enthusiastic" : text.lowercased().contains("please") ? "Polite" : "Neutral"
        return WritingAnalysis(suggestions: unique, words: words, readability: readability, tone: tone)
    }

    /// Combines suggestion lists, dropping any whose range overlaps one already kept (earlier lists win).
    static func merge(_ primary: [WritingSuggestion], _ secondary: [WritingSuggestion]) -> [WritingSuggestion] {
        var kept: [WritingSuggestion] = []
        for suggestion in primary + secondary where !kept.contains(where: { NSIntersectionRange($0.range, suggestion.range).length > 0 || $0.range == suggestion.range }) {
            kept.append(suggestion)
        }
        return kept.sorted { $0.range.location < $1.range.location }
    }

    /// Rule-based rewrite used when the on-device model is unavailable.
    static func rewrite(_ text: String, tone: WritingTone) -> String {
        var result = text as NSString
        for suggestion in analyze(text).suggestions.reversed() {
            if let replacement = suggestion.replacement { result = result.replacingCharacters(in: suggestion.range, with: replacement) as NSString }
        }
        let cleaned = result as String
        switch tone {
        case .professional: return cleaned.replacingOccurrences(of: "!", with: ".")
        case .friendly: return cleaned
        case .confident: return cleaned.replacingOccurrences(of: "I think ", with: "", options: .caseInsensitive)
        case .concise: return ["just ", "very ", "really "].reduce(cleaned) { $0.replacingOccurrences(of: $1, with: "", options: .caseInsensitive) }
        }
    }

    /// Range of the sentence containing `range`, without trailing whitespace.
    static func sentenceRange(containing range: NSRange, in text: String) -> NSRange {
        let nsText = text as NSString
        var found = range
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
            if NSLocationInRange(range.location, sentence) { found = NSUnionRange(sentence, range); stop.pointee = true }
        }
        while found.length > 0, let last = nsText.substring(with: NSRange(location: NSMaxRange(found) - 1, length: 1)).unicodeScalars.first, CharacterSet.whitespacesAndNewlines.contains(last) {
            found.length -= 1
        }
        return found
    }

    /// Case-insensitive whole-word occurrences of `phrase`.
    static func wordRanges(of phrase: String, in text: String) -> [NSRange] {
        matches(of: "(?<![\\p{L}\\p{N}'])\(NSRegularExpression.escapedPattern(for: phrase))(?![\\p{L}\\p{N}])", in: text, options: .caseInsensitive)
    }

    private static func checkSpellingAndGrammar(_ text: String) -> [WritingSuggestion] {
        let checker = NSSpellChecker.shared
        let nsText = text as NSString
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        var orthography: NSOrthography?
        var wordCount = 0
        let results = checker.check(text, range: NSRange(location: 0, length: nsText.length), types: types, options: nil, inSpellDocumentWithTag: spellTag, orthography: &orthography, wordCount: &wordCount)
        var suggestions: [WritingSuggestion] = []
        for result in results {
            if result.resultType == .spelling {
                let word = nsText.substring(with: result.range)
                let guess = checker.correction(forWordRange: result.range, in: text, language: checker.language(), inSpellDocumentWithTag: spellTag)
                    ?? checker.guesses(forWordRange: result.range, in: text, language: nil, inSpellDocumentWithTag: spellTag)?.first
                suggestions.append(WritingSuggestion(kind: .correctness, title: "Spelling", explanation: guess.map { "“\(word)” may be misspelled. Did you mean “\($0)”?" } ?? "“\(word)” may be misspelled.", original: word, replacement: guess, range: result.range, isSpelling: true))
            } else if result.resultType == .grammar {
                for detail in result.grammarDetails ?? [] {
                    guard let value = detail[NSGrammarRange] as? NSValue else { continue }
                    let local = value.rangeValue
                    let range = NSRange(location: result.range.location + local.location, length: local.length)
                    guard NSMaxRange(range) <= nsText.length, range.length > 0 else { continue }
                    let description = detail[NSGrammarUserDescription] as? String ?? "Possible grammar issue."
                    let correction = (detail[NSGrammarCorrections] as? [String])?.first
                    suggestions.append(WritingSuggestion(kind: .correctness, title: "Grammar", explanation: description, original: nsText.substring(with: range), replacement: correction, range: range))
                }
            }
        }
        return suggestions
    }

    private static func matches(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    private static func matchCase(of original: String, _ replacement: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}
