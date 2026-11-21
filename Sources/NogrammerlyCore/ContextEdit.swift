import Foundation

/// An edit a keyboard can perform with only `deleteBackward()` and `insertText(_:)`.
///
/// Keyboards see the text before the cursor, but moving the cursor by offset is unreliable across apps
/// (some count UTF-16 units, some characters). So a fix is applied by deleting back to the start of the
/// suggestion and re-typing the replacement plus everything that followed it, which leaves the cursor
/// where it was relative to the user's text.
public struct ContextEdit: Equatable, Sendable {
    /// Number of `deleteBackward()` calls; each removes one user-perceived character.
    public let deleteCount: Int
    public let insert: String

    public init(deleteCount: Int, insert: String) {
        self.deleteCount = deleteCount; self.insert = insert
    }

    /// Replaces `range` (UTF-16, as in `WritingSuggestion.range`) of `before`, the text ending at the cursor.
    /// Returns nil when the range is not inside `before` or no longer holds `expected`.
    public static func replacing(_ range: NSRange, in before: String, expected: String, with replacement: String) -> ContextEdit? {
        guard let swiftRange = Range(range, in: before), before[swiftRange] == expected else { return nil }
        return ContextEdit(deleteCount: before[swiftRange.lowerBound...].count, insert: replacement + before[swiftRange.upperBound...])
    }
}
