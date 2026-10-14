import Foundation
import FoundationModels

/// Grammar/clarity/tone checks and rewrites using Apple's on-device language model (macOS 26+ with Apple Intelligence).
/// Text never leaves the Mac. Every entry point degrades to "no result" when the model is unavailable.
@MainActor
enum AIWriter {
    /// Paragraphs longer than this are skipped; the on-device context window is small.
    private static let maxParagraphLength = 2_500
    private static var paragraphCache: [String: [WritingSuggestion]] = [:]

    static var isAvailable: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    /// Loads the model into memory ahead of the first check; a cold first request can otherwise take a minute.
    static func prewarm() {
        guard #available(macOS 26, *), isAvailable else { return }
        LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations)).prewarm()
    }

    /// Proofreads `text` paragraph by paragraph; unchanged paragraphs come from cache, so typing only re-checks the edited one.
    static func proofread(_ text: String) async -> [WritingSuggestion] {
        guard #available(macOS 26, *), isAvailable else { return [] }
        let nsText = text as NSString
        var paragraphs: [(String, NSRange)] = []
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .byParagraphs) { paragraph, range, _, _ in
            if let paragraph, paragraph.contains(where: \.isLetter), range.length <= maxParagraphLength { paragraphs.append((paragraph, range)) }
        }
        var found: [WritingSuggestion] = []
        for (paragraph, range) in paragraphs {
            if Task.isCancelled { return [] }
            let local: [WritingSuggestion]
            if let cached = paragraphCache[paragraph] {
                local = cached
            } else {
                local = await proofreadParagraph(paragraph)
                if Task.isCancelled { return [] }
                if paragraphCache.count > 500 { paragraphCache.removeAll() }
                paragraphCache[paragraph] = local
            }
            found += local.map { WritingSuggestion(kind: $0.kind, title: $0.title, explanation: $0.explanation, original: $0.original, replacement: $0.replacement, range: NSRange(location: $0.range.location + range.location, length: $0.range.length)) }
        }
        return found
    }

    static func rewrite(_ text: String, tone: WritingTone) async -> String? {
        guard #available(macOS 26, *), isAvailable else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
            Rewrite the user's text so it reads \(tone.instruction). Fix any grammar, spelling and punctuation mistakes. \
            Keep the original meaning, language, names, numbers, links and line breaks. \
            Reply with only the rewritten text: no preamble, no quotes, no explanation.
            """)
        guard let output = try? await session.respond(to: text).content.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else { return nil }
        return output
    }

    @available(macOS 26, *)
    private static func proofreadParagraph(_ paragraph: String) async -> [WritingSuggestion] {
        let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
            You are a meticulous proofreader. Report every grammar, spelling, punctuation, word-choice, clarity and tone problem in the user's text. \
            "original" must be copied verbatim from the text and be as short as possible (a few words). \
            Use kind "correctness" for grammar, spelling and punctuation; "clarity" for wordy or confusing phrasing; \
            "delivery" for tone that is too harsh, hesitant or informal; "style" for weak or repetitive word choice. \
            "replacement" must be what a fluent native speaker would naturally write (for example "he and I", not "I and he"). \
            Never report text that is already correct. Return an empty list if there are no problems.
            """)
        guard let response = try? await session.respond(to: paragraph, schema: proofreadSchema, options: GenerationOptions(sampling: .greedy)),
              let issues = try? response.content.value([GeneratedContent].self, forProperty: "issues") else { return [] }

        let nsParagraph = paragraph as NSString
        var claimed: [NSRange] = []
        var suggestions: [WritingSuggestion] = []
        for issue in issues {
            guard let original = try? issue.value(String.self, forProperty: "original"),
                  let replacement = try? issue.value(String.self, forProperty: "replacement"),
                  !original.trimmingCharacters(in: .whitespaces).isEmpty, original != replacement,
                  let range = WritingEngine.wordRanges(of: original, in: paragraph).first(where: { candidate in !claimed.contains { NSIntersectionRange($0, candidate).length > 0 } })
                    ?? exactRange(of: original, in: nsParagraph, excluding: claimed)
            else { continue }
            claimed.append(range)
            let kind = (try? issue.value(String.self, forProperty: "kind")).flatMap { SuggestionKind(rawValue: $0.capitalized) } ?? .correctness
            let explanation = (try? issue.value(String.self, forProperty: "explanation")) ?? "Suggested improvement."
            suggestions.append(WritingSuggestion(kind: kind, title: explanation, explanation: "Replace “\(original)” with “\(replacement)”.", original: nsParagraph.substring(with: range), replacement: replacement, range: range))
        }
        return suggestions
    }

    private static func exactRange(of original: String, in text: NSString, excluding claimed: [NSRange]) -> NSRange? {
        let range = text.range(of: original)
        return range.location == NSNotFound || claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) ? nil : range
    }

    @available(macOS 26, *)
    private static let proofreadSchema: GenerationSchema = {
        let string = DynamicGenerationSchema(type: String.self)
        let issue = DynamicGenerationSchema(name: "Issue", properties: [
            .init(name: "original", description: "Exact text copied verbatim from the input that has the problem (a few words)", schema: string),
            .init(name: "replacement", description: "Corrected text that should replace original", schema: string),
            .init(name: "kind", schema: DynamicGenerationSchema(name: "Kind", anyOf: ["correctness", "clarity", "delivery", "style"])),
            .init(name: "explanation", description: "Why it should change, under 10 words", schema: string)
        ])
        let report = DynamicGenerationSchema(name: "Report", properties: [.init(name: "issues", schema: DynamicGenerationSchema(arrayOf: issue, maximumElements: 20))])
        // Building from these literals cannot fail; a failure would be a programming error caught on first launch.
        return try! GenerationSchema(root: report, dependencies: [])
    }()
}
