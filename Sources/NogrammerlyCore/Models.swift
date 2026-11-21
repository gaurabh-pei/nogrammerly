#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

public enum WritingTone: String, CaseIterable, Sendable {
    case professional = "Professional"
    case friendly = "Friendly"
    case confident = "Confident"
    case concise = "Concise"

    public var instruction: String {
        switch self {
        case .professional: "polished, courteous and professional"
        case .friendly: "warm, friendly and approachable"
        case .confident: "confident and direct, without hedging words like \"I think\" or \"just\""
        case .concise: "as concise as possible, removing filler while keeping every key point"
        }
    }
}

public enum SuggestionKind: String, CaseIterable, Sendable {
    case correctness = "Correctness"
    case clarity = "Clarity"
    case delivery = "Delivery"
    case style = "Style"

    public var color: PlatformColor {
        switch self { case .correctness: .systemRed; case .clarity: .systemBlue; case .delivery: .systemPurple; case .style: .systemOrange }
    }
}

public struct WritingSuggestion: Equatable, Sendable {
    public let id = UUID()
    public let kind: SuggestionKind
    public let title: String
    public let explanation: String
    /// The exact text at `range` when the suggestion was made; replacements are refused if the field no longer matches.
    public let original: String
    public let replacement: String?
    public let range: NSRange
    public let isSpelling: Bool

    public init(kind: SuggestionKind, title: String, explanation: String, original: String, replacement: String?, range: NSRange, isSpelling: Bool = false) {
        self.kind = kind; self.title = title; self.explanation = explanation
        self.original = original; self.replacement = replacement; self.range = range; self.isSpelling = isSpelling
    }

    public var ignoreKey: String { "\(title)|\(original.lowercased())" }
}

public struct WritingAnalysis: Sendable {
    public let suggestions: [WritingSuggestion]
    public let words: Int
    public let readability: Int
    public let tone: String

    public init(suggestions: [WritingSuggestion], words: Int, readability: Int, tone: String) {
        self.suggestions = suggestions; self.words = words; self.readability = readability; self.tone = tone
    }
}
