import Foundation
import NogrammerlyCore

/// Pure translation from harper-ls LSP payloads to `WritingSuggestion`s. No process and no I/O, so it is
/// unit-tested from captured frames (Tests/NogrammerlyTests/Fixtures).
///
/// Positions: LSP `Position.character` counts UTF-16 code units, which is what `NSRange` counts, so the only
/// conversion is line/character → absolute offset. (harper-cli's JSON spans are Unicode scalar offsets instead;
/// this mapper never sees them. The `span` inside `HarperIgnoreLint` arguments is also scalar-based and is ignored.)
enum HarperMapper {
    typealias JSON = [String: Any]

    /// Absolute UTF-16 offsets where each line starts. Only LF ends a line: harper-ls 3.2.0 computes positions that
    /// way (harper-ls/src/pos_conv.rs), so a lone CR stays inside its line and CRLF ends at the LF.
    static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A { starts.append(i + 1) }
        return starts
    }

    /// Converts an LSP `Position` to a UTF-16 offset, or nil when it does not fall inside `text`.
    static func offset(of position: JSON?, lineStarts: [Int], length: Int) -> Int? {
        guard let line = position?["line"] as? Int, let character = position?["character"] as? Int,
              line >= 0, character >= 0, line < lineStarts.count else { return nil }
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        let offset = lineStarts[line] + character
        return offset <= lineEnd && offset <= length ? offset : nil
    }

    /// Converts an LSP `Range` to an `NSRange`, or nil when it is reversed or out of bounds.
    static func range(of lspRange: JSON?, lineStarts: [Int], length: Int) -> NSRange? {
        guard let start = offset(of: lspRange?["start"] as? JSON, lineStarts: lineStarts, length: length),
              let end = offset(of: lspRange?["end"] as? JSON, lineStarts: lineStarts, length: length),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: harper-ls 3.2.0 code-action range workaround
    //
    // harper-ls reports diagnostics and edits in UTF-16 code units (correct), but reads the *request* range of
    // `textDocument/codeAction` as Unicode-scalar offsets (https://github.com/Automattic/harper/issues/4992). After
    // emoji or other astral characters the two differ, and once the drift exceeds the flagged span a request with the
    // diagnostic's own range returns no actions. Requesting the union of both readings works whether or not the bug
    // is fixed upstream; `actions(_:for:in:)` then keeps only this diagnostic's group.

    /// LSP range to send with `textDocument/codeAction` for `diagnosticRange`: union of UTF-16 and scalar readings.
    static func codeActionRange(for diagnosticRange: JSON?, in text: NSString, lineStarts starts: [Int]) -> JSON? {
        guard let start = diagnosticRange?["start"] as? JSON, let end = diagnosticRange?["end"] as? JSON,
              let startLine = start["line"] as? Int, let endLine = end["line"] as? Int,
              let startOffset = offset(of: start, lineStarts: starts, length: text.length),
              let endOffset = offset(of: end, lineStarts: starts, length: text.length),
              let startUnits = start["character"] as? Int, let endUnits = end["character"] as? Int else { return diagnosticRange }
        func scalars(line: Int, to offset: Int) -> Int {
            text.substring(with: NSRange(location: starts[line], length: offset - starts[line])).unicodeScalars.count
        }
        return ["start": ["line": startLine, "character": min(startUnits, scalars(line: startLine, to: startOffset))],
                "end": ["line": endLine, "character": max(endUnits, scalars(line: endLine, to: endOffset))]]
    }

    /// Splits a code-action list into per-lint groups (quick fixes, then that lint's commands) and returns the group
    /// for `diagnostic`: matched by the `HarperIgnoreLint` message, then by edits on the diagnostic's own range.
    static func actions(_ all: [JSON], for diagnostic: JSON, in text: NSString, lineStarts starts: [Int]) -> [JSON] {
        var groups: [[JSON]] = []
        var previousWasEdit = false
        var groupHasIgnore = false
        for action in all {
            let isEdit = action["edit"] != nil
            let isIgnore = action["command"] as? String == "HarperIgnoreLint"
            // A new lint starts with its first fix, or with its ignore command when it has no fixes.
            if groups.isEmpty || (isEdit && !previousWasEdit) || (isIgnore && groupHasIgnore) { groups.append([]); groupHasIgnore = false }
            if isIgnore { groupHasIgnore = true }
            groups[groups.count - 1].append(action)
            previousWasEdit = isEdit
        }
        let message = diagnostic["message"] as? String
        let target = range(of: diagnostic["range"] as? JSON, lineStarts: starts, length: text.length)
        func ignoreMessage(_ group: [JSON]) -> String? {
            group.lazy.compactMap { action -> String? in
                guard action["command"] as? String == "HarperIgnoreLint", let args = action["arguments"] as? [Any] else { return nil }
                return (args.dropFirst().first as? JSON)?["message"] as? String
            }.first
        }
        func editsHitTarget(_ group: [JSON], exactly: Bool) -> Bool {
            guard let target else { return false }
            return Fixes(actions: group).edits.contains { edit in
                guard let editRange = range(of: edit.range, lineStarts: starts, length: text.length) else { return false }
                return editRange == target || (!exactly && NSIntersectionRange(editRange, target).length > 0)
            }
        }
        let byMessage = groups.filter { ignoreMessage($0) == message }
        if byMessage.count == 1 { return byMessage[0] }
        let candidates = byMessage.isEmpty ? groups : byMessage
        // Overlapping lints can share a message: an edit on exactly this range beats one that merely overlaps it.
        return candidates.first { editsHitTarget($0, exactly: true) } ?? candidates.first { editsHitTarget($0, exactly: false) }
            ?? byMessage.first ?? []
    }

    /// What the code actions for one diagnostic say: replacement edits and Harper's lint kind (carried in the
    /// arguments of its `HarperIgnoreLint` command; the diagnostic itself only names the rule).
    struct Fixes {
        var edits: [(range: JSON, newText: String)] = []
        var lintKind: String?

        init(actions: [JSON]?) {
            for action in actions ?? [] {
                if let changes = (action["edit"] as? JSON)?["changes"] as? [String: [JSON]] {
                    for edit in changes.values.joined() {
                        if let range = edit["range"] as? JSON, let newText = edit["newText"] as? String { edits.append((range, newText)) }
                    }
                }
                if action["command"] as? String == "HarperIgnoreLint", let arguments = action["arguments"] as? [Any] {
                    lintKind = (arguments.dropFirst().first as? JSON)?["lint_kind"] as? String
                }
            }
        }
    }

    /// Maps `publishDiagnostics` diagnostics and the code actions fetched for each (same order; nil when
    /// none were fetched) to suggestions with ranges relative to `text`. Out-of-range items are dropped.
    static func map(diagnostics: [JSON], actions: [[JSON]?], in text: String) -> [WritingSuggestion] {
        let nsText = text as NSString
        let starts = lineStarts(of: nsText)
        var mapped: [WritingSuggestion] = []
        for (index, diagnostic) in diagnostics.enumerated() {
            guard let diagnosticRange = range(of: diagnostic["range"] as? JSON, lineStarts: starts, length: nsText.length),
                  diagnosticRange.length > 0 else { continue }
            let rule = diagnostic["code"] as? String ?? (diagnostic["code"] as? Int).map(String.init) ?? "Harper"
            let message = diagnostic["message"] as? String ?? "Possible issue."
            let fixes = Fixes(actions: (index < actions.count ? actions[index] : nil).map { Self.actions($0, for: diagnostic, in: nsText, lineStarts: starts) })
            // Harper's quick fixes may cover a different span than the diagnostic (e.g. "a a" → "a"); apply what it
            // edits. A pure insertion (empty range) is widened to the diagnostic so the replacement keeps the word.
            let edits = fixes.edits.compactMap { edit -> (range: NSRange, text: String)? in
                range(of: edit.range, lineStarts: starts, length: nsText.length).map { ($0, edit.newText) }
            }
            let suggestionRange = edits.first.map { $0.range.length > 0 ? $0.range : NSUnionRange(diagnosticRange, $0.range) } ?? diagnosticRange
            let replacements = edits.compactMap { applied($0, within: suggestionRange, of: nsText) }
            let original = nsText.substring(with: suggestionRange)
            mapped.append(WritingSuggestion(
                kind: kind(rule: rule, lintKind: fixes.lintKind),
                title: title(for: rule),
                explanation: explanation(message, replacement: replacements.first, alternatives: Array(replacements.dropFirst())),
                original: original,
                replacement: replacements.first,
                range: suggestionRange,
                isSpelling: rule == "SpellCheck"))
        }
        return mapped
    }

    /// The text `range` would read after applying `edit`, or nil when the edit reaches outside `range`.
    static func applied(_ edit: (range: NSRange, text: String), within range: NSRange, of text: NSString) -> String? {
        guard edit.range.location >= range.location, NSMaxRange(edit.range) <= NSMaxRange(range) else { return nil }
        let before = text.substring(with: NSRange(location: range.location, length: edit.range.location - range.location))
        let after = text.substring(with: NSRange(location: NSMaxRange(edit.range), length: NSMaxRange(range) - NSMaxRange(edit.range)))
        return before + edit.text + after
    }

    /// Rules that judge how a message lands rather than whether it is correct.
    static let deliveryRules: Set<String> = ["Hedging", "FillerWords", "BoringWords"]

    /// Harper `LintKind` (from the code action, when fetched) → Nogrammerly's four categories.
    static func kind(rule: String, lintKind: String?) -> SuggestionKind {
        if deliveryRules.contains(rule) { return .delivery }
        switch lintKind {
        case "WordChoice", "Repetition", "Readability": return .clarity
        case "Enhancement", "Style", "Redundancy", "Regionalism": return .style
        // Spelling, Typo, Punctuation, Capitalization, Grammar, Agreement, Usage, Eggcorn, Malapropism,
        // BoundaryError, Nonstandard, Formatting, Miscellaneous, or unknown (no code action fetched).
        default: return .correctness
        }
    }

    /// "ItsContraction" → "Its Contraction (Harper)". The ignore key is built from this, so it follows the rule name.
    static func title(for rule: String) -> String {
        var words = ""
        let scalars = Array(rule.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            let isUpper = CharacterSet.uppercaseLetters.contains(scalar)
            if i > 0, isUpper, !CharacterSet.uppercaseLetters.contains(scalars[i - 1]) || (i + 1 < scalars.count && CharacterSet.lowercaseLetters.contains(scalars[i + 1])) {
                words.append(" ")
            }
            words.unicodeScalars.append(scalar)
        }
        return "\(words) (Harper)"
    }

    /// Harper messages use Markdown backticks; show typographic quotes like the rest of the app.
    static func explanation(_ message: String, replacement: String?, alternatives: [String]) -> String {
        let pieces = message.components(separatedBy: "`")
        var text = message
        if pieces.count > 1, pieces.count % 2 == 1 { // balanced backticks only
            text = pieces.enumerated().map { i, piece in i == 0 ? piece : (i % 2 == 1 ? "“" : "”") + piece }.joined()
        }
        if let replacement { text += " Replace with “\(replacement)”." }
        if !alternatives.isEmpty { text += " Also: " + alternatives.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + "." }
        return text
    }

}
