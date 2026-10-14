import Foundation
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

    @Test func wordRangesMatchWholeWordsOnly() {
        #expect(WritingEngine.wordRanges(of: "just", in: "Just adjust it, just now.") == [NSRange(location: 0, length: 4), NSRange(location: 16, length: 4)])
    }

    @Test func sentenceRangeCoversContainingSentence() {
        let text = "First one. Second one here."
        let range = WritingEngine.sentenceRange(containing: NSRange(location: 14, length: 3), in: text)
        #expect((text as NSString).substring(with: range).trimmingCharacters(in: .whitespaces) == "Second one here.")
    }
}
