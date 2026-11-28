import Foundation
import NogrammerlyCore
import Testing
@testable import Nogrammerly

@Suite struct WritingEngineTests {
    @Test func styleRuleSuggestsSimplerWord() {
        let suggestions = WritingEngine.analyze("We utilize this tool daily.").suggestions
        #expect(suggestions.contains { $0.original.lowercased() == "utilize" && $0.replacement == "use" })
    }

    @Test func flagsMisspelling() {
        let suggestions = WritingEngine.analyze("I recieve messages.").suggestions
        #expect(suggestions.contains { $0.original == "recieve" })
    }

    @Test func cleanTextHasNoSuggestions() {
        #expect(WritingEngine.analyze("The meeting starts at noon.").suggestions.isEmpty)
    }

    static func harperSpelling(_ word: String, _ replacement: String, in text: String) -> WritingSuggestion {
        WritingSuggestion(kind: .correctness, title: "Spell Check (Harper)",
                          explanation: "Did you mean to spell “\(word)” this way? Replace with “\(replacement)”.",
                          original: word, replacement: replacement, range: (text as NSString).range(of: word), isSpelling: true)
    }

    @Test func appleCorrectionReplacesWeakHarperSuggestion() throws {
        let text = "We need acess to the building on wenesday."
        let fixed = MacWritingEngine.preferAppleCorrections([Self.harperSpelling("acess", "ace's", in: text), Self.harperSpelling("wenesday", "weekday", in: text)], in: text)
        #expect(fixed.map(\.replacement) == ["access", "Wednesday"])
        let first = try #require(fixed.first)
        #expect(first.range == (text as NSString).range(of: "acess") && first.isSpelling)
        #expect(first.explanation.contains("Replace with “access”") && first.explanation.contains("Also: “ace's”"))
    }

    @Test func harperKeepsWordsAppleAcceptsAndNonSpelling() {
        let text = "We shipped it, irregardless of the delay."
        let harper = Self.harperSpelling("irregardless", "regardless", in: text)
        let grammar = WritingSuggestion(kind: .correctness, title: "Its Contraction (Harper)", explanation: "x", original: "shipped",
                                        replacement: "ship", range: (text as NSString).range(of: "shipped"))
        let apple = WritingSuggestion(kind: .correctness, title: "Spelling", explanation: "x", original: "irregardless",
                                      replacement: "irregardless", range: (text as NSString).range(of: "irregardless"), isSpelling: true)
        #expect(MacWritingEngine.preferAppleCorrections([harper, grammar, apple], in: text) == [harper, grammar, apple])
    }

    /// A primary finding that overlaps a long sentence drops the "Long sentence" finding, but must not take the
    /// sentence's dictionary results with it.
    @Test func primaryFindingKeepsSystemSpellingInLongSentence() {
        let text = "We will go over every single item on the long agenda together today so that the whole team knows exactly what is happening next week and nobody feels left out of the recieve process at all."
        let ns = text as NSString
        let primary = WritingSuggestion(kind: .correctness, title: "Test (Primary)", explanation: "x", original: "agenda", replacement: "plan", range: ns.range(of: "agenda"))
        let plain = WritingEngine.analyze(text).suggestions
        #expect(plain.contains { $0.title == "Long sentence" })
        let merged = WritingEngine.analyze(text, primary: [primary], systemChecker: true).suggestions
        #expect(merged.contains { $0.title == "Test (Primary)" })
        #expect(merged.contains { $0.isSpelling && $0.original == "recieve" })
    }

    @Test func noPrimaryMatchesPlainAnalyze() {
        let text = "I think we should utilize the new workflow in order to recieve approvals faster!!"
        #expect(WritingEngine.analyze(text, primary: [], systemChecker: true).suggestions.map(\.title) == WritingEngine.analyze(text).suggestions.map(\.title))
    }

    @Test func wordRangesMatchWholeWordsOnly() {
        #expect(WritingEngine.wordRanges(of: "just", in: "Just adjust it, just now.") == [NSRange(location: 0, length: 4), NSRange(location: 16, length: 4)])
    }

    @Test func sentenceRangeCoversContainingSentence() {
        let text = "First one. Second one here."
        let range = WritingEngine.sentenceRange(containing: NSRange(location: 14, length: 3), in: text)
        #expect((text as NSString).substring(with: range).trimmingCharacters(in: .whitespaces) == "Second one here.")
    }
}
