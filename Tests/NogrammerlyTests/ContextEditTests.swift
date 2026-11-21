import Foundation
import Testing
import NogrammerlyCore

@Suite struct ContextEditTests {
    /// Applies an edit the way a keyboard would, so the tests check the visible result.
    private func apply(_ edit: ContextEdit, to before: String) -> String {
        String(before.dropLast(edit.deleteCount)) + edit.insert
    }

    @Test func replacesWordInsideTextBeforeCursor() throws {
        let before = "I will recieve it today"
        let range = (before as NSString).range(of: "recieve")
        let edit = try #require(ContextEdit.replacing(range, in: before, expected: "recieve", with: "receive"))
        #expect(edit.deleteCount == "recieve it today".count)
        #expect(apply(edit, to: before) == "I will receive it today")
    }

    @Test func countsEmojiAndAccentsAsSingleDeletes() throws {
        let before = "Café 👍🏽 teh end"
        let range = (before as NSString).range(of: "teh")
        let edit = try #require(ContextEdit.replacing(range, in: before, expected: "teh", with: "the"))
        #expect(edit.deleteCount == 7)
        #expect(apply(edit, to: before) == "Café 👍🏽 the end")
    }

    @Test func refusesStaleSuggestion() {
        let before = "I will receive it"
        let range = NSRange(location: 7, length: 7)
        #expect(ContextEdit.replacing(range, in: before, expected: "recieve", with: "receive") == nil)
        #expect(ContextEdit.replacing(NSRange(location: 40, length: 3), in: before, expected: "abc", with: "x") == nil)
    }

    @Test func replacesWholeSentenceForRewrites() throws {
        let before = "Hi. thanks so much!! See you"
        let range = (before as NSString).range(of: "thanks so much!!")
        let edit = try #require(ContextEdit.replacing(range, in: before, expected: "thanks so much!!", with: "Thank you very much."))
        #expect(apply(edit, to: before) == "Hi. Thank you very much. See you")
    }
}
