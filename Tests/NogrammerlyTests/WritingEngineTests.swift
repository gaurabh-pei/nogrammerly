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

    @Test func wordRangesMatchWholeWordsOnly() {
        #expect(WritingEngine.wordRanges(of: "just", in: "Just adjust it, just now.") == [NSRange(location: 0, length: 4), NSRange(location: 16, length: 4)])
    }

    @Test func sentenceRangeCoversContainingSentence() {
        let text = "First one. Second one here."
        let range = WritingEngine.sentenceRange(containing: NSRange(location: 14, length: 3), in: text)
        #expect((text as NSString).substring(with: range).trimmingCharacters(in: .whitespaces) == "Second one here.")
    }
}
