import AppKit

enum WritingTone: String, CaseIterable {
    case professional = "Professional"
    case friendly = "Friendly"
    case confident = "Confident"
    case concise = "Concise"

    var instruction: String {
        switch self {
        case .professional: "polished, courteous and professional"
        case .friendly: "warm, friendly and approachable"
        case .confident: "confident and direct, without hedging words like \"I think\" or \"just\""
        case .concise: "as concise as possible, removing filler while keeping every key point"
        }
    }
}

enum SuggestionKind: String, CaseIterable {
    case correctness = "Correctness"
    case clarity = "Clarity"
    case delivery = "Delivery"
    case style = "Style"

    var color: NSColor {
        switch self { case .correctness: .systemRed; case .clarity: .systemBlue; case .delivery: .systemPurple; case .style: .systemOrange }
    }
}

struct WritingSuggestion: Equatable {
    let id = UUID()
    let kind: SuggestionKind
    let title: String
    let explanation: String
    /// The exact text at `range` when the suggestion was made; replacements are refused if the field no longer matches.
    let original: String
    let replacement: String?
    let range: NSRange
    let isSpelling: Bool

    init(kind: SuggestionKind, title: String, explanation: String, original: String, replacement: String?, range: NSRange, isSpelling: Bool = false) {
        self.kind = kind; self.title = title; self.explanation = explanation
        self.original = original; self.replacement = replacement; self.range = range; self.isSpelling = isSpelling
    }

    var ignoreKey: String { "\(title)|\(original.lowercased())" }
}

struct WritingAnalysis {
    let suggestions: [WritingSuggestion]
    let words: Int
    let readability: Int
    let tone: String
}
