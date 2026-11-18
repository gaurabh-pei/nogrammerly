import Foundation
import Testing
@testable import Nogrammerly

/// Mapper tests driven by real harper-ls 3.2.0 traffic (Fixtures/harper-ls-3.2.0-frames.json, recorded with the
/// same requests HarperEngine sends). No sidecar needed.
@Suite struct HarperMapperTests {
    struct Case { let text: String; let diagnostics: [[String: Any]]; let actions: [[[String: Any]]?] }

    static let fixture: [String: Any] = {
        let url = Bundle.module.url(forResource: "harper-ls-3.2.0-frames", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    static func load(_ name: String) -> Case {
        let entry = (fixture["cases"] as! [String: Any])[name] as! [String: Any]
        let diagnostics = (entry["publishDiagnostics"] as! [String: Any])["diagnostics"] as! [[String: Any]]
        return Case(text: entry["text"] as! String, diagnostics: diagnostics, actions: (entry["codeActions"] as! [Any]).map { $0 as? [[String: Any]] })
    }

    static func mapped(_ name: String) -> (text: NSString, suggestions: [WritingSuggestion]) {
        let c = load(name)
        return (c.text as NSString, HarperMapper.map(diagnostics: c.diagnostics, actions: c.actions, in: c.text))
    }

    @Test func fixtureComesFromPinnedServer() {
        #expect((Self.fixture["server"] as? [String: Any])?["version"] as? String == HarperEngine.pinnedVersion)
    }

    @Test func spellingAfterPlainText() throws {
        let (text, suggestions) = Self.mapped("sample-email")
        let s = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(s.range == text.range(of: "recieve"))
        #expect(s.original == "recieve" && s.replacement == "receive")
        #expect(s.isSpelling && s.kind == .correctness)
        #expect(s.title == "Spell Check (Harper)")
        #expect(s.ignoreKey == "Spell Check (Harper)|recieve")
    }

    /// Emoji (surrogate pairs, a skin-tone modifier) and accented letters before the findings: every range must
    /// still land on the right UTF-16 units, and the fixes after the emoji must survive the 3.2.0 range bug.
    @Test func emojiAndAccentsKeepOffsets() throws {
        let (text, suggestions) = Self.mapped("emoji-accents")
        #expect(suggestions.count == 6)
        for s in suggestions { #expect(text.substring(with: s.range) == s.original) }
        let teh = try #require(suggestions.first { $0.original == "teh" })
        #expect(teh.range == text.range(of: "teh"))
        #expect(teh.replacement == "the")
        let pronoun = try #require(suggestions.first { $0.title.hasPrefix("Capitalize Personal Pronouns") })
        #expect(pronoun.range == NSRange(location: text.range(of: " i ").location + 1, length: 1))
        #expect(pronoun.replacement == "I")
        let its = try #require(suggestions.first { $0.original == "its" })
        #expect(its.replacement == "it's")
        #expect(its.explanation.contains("“it has”")) // second fix listed as an alternative
        #expect(suggestions.filter(\.isSpelling).map(\.original).sorted() == ["dont", "thinkk"])
    }

    /// ZWJ family emoji, a flag, a math-script letter (U+1D4B3) and findings on later lines.
    @Test func multiByteOffsetsMidDocument() throws {
        let (text, suggestions) = Self.mapped("multibyte-midline")
        for s in suggestions { #expect(text.substring(with: s.range) == s.original) }
        #expect(suggestions.contains { $0.original == "recieve" && $0.range == text.range(of: "recieve") && $0.replacement == "receive" })
        let go = try #require(suggestions.first { $0.title.hasPrefix("Pronoun Verb Agreement") })
        #expect(go.range == text.range(of: "go", options: .backwards))
        #expect(go.replacement != nil)
    }

    @Test func crlfLineBreaks() throws {
        let (text, suggestions) = Self.mapped("crlf")
        for s in suggestions { #expect(text.substring(with: s.range) == s.original) }
        #expect(suggestions.contains { $0.original == "recieve" && $0.range == text.range(of: "recieve") })
        #expect(suggestions.contains { $0.range == text.range(of: "go") })
    }

    @Test func cleanTextMapsToNothing() {
        #expect(Self.mapped("clean").suggestions.isEmpty)
    }

    @Test func outOfRangeDiagnosticsAreDroppedNotCrashed() {
        let text = "Short 😀 text."
        let bad: [[String: Any]] = [
            ["code": "SpellCheck", "message": "x", "range": ["start": ["line": 0, "character": 40], "end": ["line": 0, "character": 45]]],
            ["code": "SpellCheck", "message": "x", "range": ["start": ["line": 3, "character": 0], "end": ["line": 3, "character": 1]]],
            ["code": "SpellCheck", "message": "x", "range": ["start": ["line": 0, "character": 5], "end": ["line": 0, "character": 2]]],
            ["code": "SpellCheck", "message": "x"]
        ]
        #expect(HarperMapper.map(diagnostics: bad, actions: [], in: text).isEmpty)
    }

    @Test func lineStartsHandleAllBreaks() {
        #expect(HarperMapper.lineStarts(of: "a\nb\r\nc\rd") == [0, 2, 5, 7])
        #expect(HarperMapper.lineStarts(of: "") == [0])
    }

    @Test func codeActionRangeCoversScalarReading() {
        let text = "👍🏽 teh" as NSString // 4 UTF-16 units, 2 scalars before the space
        let range: [String: Any] = ["start": ["line": 0, "character": 5], "end": ["line": 0, "character": 8]]
        let union = HarperMapper.codeActionRange(for: range, in: text, lineStarts: [0])
        #expect((union?["start"] as? [String: Any])?["character"] as? Int == 3)
        #expect((union?["end"] as? [String: Any])?["character"] as? Int == 8)
    }

    @Test func titlesAndKinds() {
        #expect(HarperMapper.title(for: "ItsContraction") == "Its Contraction (Harper)")
        #expect(HarperMapper.title(for: "SpellCheck") == "Spell Check (Harper)")
        #expect(HarperMapper.title(for: "AAndAn") == "A And An (Harper)")
        #expect(HarperMapper.kind(rule: "SpellCheck", lintKind: "Spelling") == .correctness)
        #expect(HarperMapper.kind(rule: "X", lintKind: "Typo") == .correctness)
        #expect(HarperMapper.kind(rule: "X", lintKind: "WordChoice") == .clarity)
        #expect(HarperMapper.kind(rule: "X", lintKind: "Redundancy") == .style)
        #expect(HarperMapper.kind(rule: "Hedging", lintKind: "Style") == .delivery)
        #expect(HarperMapper.kind(rule: "X", lintKind: nil) == .correctness)
    }

    @Test func chunksCoverTextAtLineBoundaries() {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet. ", count: 20) // 560 units
        let text = (Array(repeating: paragraph + "\n\n", count: 12).joined() + String(repeating: "x", count: 5_000)) as NSString
        let chunks = HarperEngine.chunks(of: text)
        #expect(chunks.first?.location == 0)
        #expect(chunks.reduce(0) { $0 + $1.length } == text.length)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        for chunk in chunks.dropLast() {
            #expect(chunk.length <= HarperEngine.chunkHardLimit)
            #expect(text.character(at: NSMaxRange(chunk) - 1) == 0x0A) // ends at a line break
        }
        #expect(HarperEngine.chunks(of: "") == [NSRange(location: 0, length: 0)])
    }
}
