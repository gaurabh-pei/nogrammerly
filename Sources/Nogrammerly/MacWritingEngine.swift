import Foundation
import NogrammerlyCore

/// The Mac app's checker: Harper (bundled harper-ls) when it is available, otherwise the shared `WritingEngine`
/// with the system dictionary. It lives in the Mac target, not NogrammerlyCore, because Harper is a spawned
/// process that only exists on macOS; Core stays the same for the iOS app and keyboard.
enum MacWritingEngine {
    private static let appleSecondary = ProcessInfo.processInfo.environment["NOGRAMMERLY_APPLE_SECONDARY"] == "1"
        || UserDefaults.standard.bool(forKey: "NogrammerlyAppleSecondary")

    static func analyze(_ text: String) -> WritingAnalysis {
        analyze(text, harper: HarperEngine.shared)
    }

    /// `harper` nil means the Apple checker (NOGRAMMERLY_ENGINE=apple, or harper-ls not bundled). A lint that
    /// fails or is not ready also falls back to the Apple checker.
    static func analyze(_ text: String, harper: HarperEngine?) -> WritingAnalysis {
        guard let harper, let found = harper.lint(text) else { return WritingEngine.analyze(text) }
        // Harper is primary; the local phrase rules fill in what it does not cover ("utilize", "I think").
        // NOGRAMMERLY_APPLE_SECONDARY=1 also merges the Apple checker behind both.
        return WritingEngine.analyze(text, primary: found, systemChecker: appleSecondary)
    }
}
