import AppKit
import Foundation
import Testing
import NogrammerlyCore
@testable import Nogrammerly

/// Numbers for the PR description. Opt-in: NOGRAMMERLY_BENCH=1 swift test --filter HarperBenchmark
/// Prints one JSON object per measurement, prefixed "BENCH ".
@Suite(.serialized, .enabled(if: HarperTestSupport.available && ProcessInfo.processInfo.environment["NOGRAMMERLY_BENCH"] == "1"))
struct HarperBenchmarkTests {
    static func report(_ name: String, _ values: [String: Any]) {
        var all = values; all["name"] = name
        let data = try! JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        print("BENCH " + String(decoding: data, as: UTF8.self))
    }

    static func ms(_ seconds: TimeInterval) -> Double { (seconds * 100_000).rounded() / 100 }

    static func time(_ body: () -> Void) -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    static func percentile(_ values: [TimeInterval], _ p: Double) -> Double {
        let sorted = values.sorted()
        return ms(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))])
    }

    static func rssKB(_ pid: Int32) -> Int {
        let ps = Process(); let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-o", "rss=", "-p", "\(pid)"]; ps.standardOutput = out
        try? ps.run(); ps.waitUntilExit()
        return Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    static let corpus: [String: [String]] = {
        let url = Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Fixtures")!
        let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return json.compactMapValues { $0 as? [String] }
    }()

    @Test func latencyAndMemory() throws {
        // Cold: spawn + initialize + first document (dictionary load).
        var engine: HarperEngine!
        let cold = Self.time { engine = try? HarperTestSupport.makeEngine() }
        defer { engine?.stop() }
        let message = Self.corpus["errors"]![0]
        var first: [WritingSuggestion]?
        let firstLint = Self.time { first = engine.lint(message) }
        Self.report("cold_start", ["spawn_init_warm_ms": Self.ms(cold), "first_field_lint_ms": Self.ms(firstLint), "first_field_findings": first?.count ?? -1])

        // Warm: one keystroke at a time in a ~300-char field (every call is a cache miss).
        var text = Self.corpus["errors"]![3]
        var keystrokes: [TimeInterval] = []
        for i in 0..<60 { text += i % 5 == 4 ? " " : "x"; keystrokes.append(Self.time { _ = engine.lint(text) }) }
        let unchanged = (0..<60).map { _ in Self.time { _ = engine.lint(text) } }
        // Full analyze() on the main thread path (Harper + local rules + merge), warm.
        var analyzeTimes: [TimeInterval] = []
        for i in 0..<60 { text += i % 5 == 4 ? " " : "y"; analyzeTimes.append(Self.time { _ = MacWritingEngine.analyze(text, harper: engine) }) }
        var appleTimes: [TimeInterval] = []
        for i in 0..<60 { text += i % 5 == 4 ? " " : "z"; appleTimes.append(Self.time { _ = MacWritingEngine.analyze(text, harper: nil) }) }
        Self.report("warm_short_field", [
            "chars": (text as NSString).length,
            "keystroke_lint_p50_ms": Self.percentile(keystrokes, 0.5), "keystroke_lint_p95_ms": Self.percentile(keystrokes, 0.95),
            "unchanged_p50_ms": Self.percentile(unchanged, 0.5),
            "analyze_harper_p50_ms": Self.percentile(analyzeTimes, 0.5), "analyze_harper_p95_ms": Self.percentile(analyzeTimes, 0.95),
            "analyze_apple_p50_ms": Self.percentile(appleTimes, 0.5), "analyze_apple_p95_ms": Self.percentile(appleTimes, 0.95)])

        // 20,000 characters: every chunk new, then one keystroke in the middle.
        var long = ""
        var k = 0
        while (long as NSString).length < WritingEngine.maxLength - 400 {
            long += Self.corpus[k % 2 == 0 ? "errors" : "clean"]![k % 15] + "\n\n"; k += 1
        }
        let fresh = try HarperTestSupport.makeEngine(); defer { fresh.stop() }
        var longFound: [WritingSuggestion]?
        let longCold = Self.time { longFound = fresh.lint(long, deadline: Date(timeIntervalSinceNow: 30)) }
        let middle = (long as NSString).length / 2
        let edited = (long as NSString).replacingCharacters(in: NSRange(location: middle, length: 0), with: "q")
        let longEdit = Self.time { _ = fresh.lint(edited) }
        let longAnalyze = Self.time { _ = MacWritingEngine.analyze(edited + " ", harper: fresh) }
        let longApple = Self.time { _ = MacWritingEngine.analyze(edited, harper: nil) }
        Self.report("field_20k", [
            "chars": (long as NSString).length, "chunks": HarperEngine.chunks(of: long as NSString).count, "findings": longFound?.count ?? -1,
            "all_chunks_new_ms": Self.ms(longCold), "one_keystroke_ms": Self.ms(longEdit),
            "analyze_harper_after_edit_ms": Self.ms(longAnalyze), "analyze_apple_ms": Self.ms(longApple),
            "sidecar_rss_kb": Self.rssKB(fresh.processIdentifier ?? 0)])
        Self.report("rss_after_short_fields", ["sidecar_rss_kb": Self.rssKB(engine.processIdentifier ?? 0)])
    }

    @Test func findingsDeltaAndNoise() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        func counts(_ texts: [String]) -> (harper: Int, apple: Int, harperOnly: Int, rules: [String: Int]) {
            var harper = 0, apple = 0, harperOnly = 0
            var rules: [String: Int] = [:]
            for text in texts {
                harper += MacWritingEngine.analyze(text, harper: engine).suggestions.count
                apple += MacWritingEngine.analyze(text, harper: nil).suggestions.count
                let raw = engine.lint(text) ?? []
                harperOnly += raw.count
                for item in raw { rules[item.title, default: 0] += 1 }
            }
            return (harper, apple, harperOnly, rules)
        }
        let errors = counts(Self.corpus["errors"]!)
        let clean = counts(Self.corpus["clean"]!)
        let chat = counts(Self.corpus["chat"]!)
        let chatFlagged = Self.corpus["chat"]!.map { (h: (engine.lint($0) ?? []).isEmpty ? 0 : 1, a: MacWritingEngine.analyze($0, harper: nil).suggestions.isEmpty ? 0 : 1) }
        Self.report("findings_chat_corpus", ["texts": Self.corpus["chat"]!.count, "messages_flagged_harper_raw": chatFlagged.map(\.h).reduce(0, +), "messages_flagged_apple_analyze": chatFlagged.map(\.a).reduce(0, +), "analyze_harper": chat.harper, "analyze_apple": chat.apple, "harper_raw": chat.harperOnly, "rules": chat.rules])
        Self.report("findings_errors_corpus", ["texts": Self.corpus["errors"]!.count, "analyze_harper": errors.harper, "analyze_apple": errors.apple, "harper_raw": errors.harperOnly, "rules": errors.rules])
        Self.report("findings_clean_corpus", ["texts": Self.corpus["clean"]!.count, "analyze_harper": clean.harper, "analyze_apple": clean.apple, "harper_raw": clean.harperOnly, "rules": clean.rules])
        // Per-text detail for the error corpus: which injected slips each engine caught.
        for (i, text) in Self.corpus["errors"]!.enumerated() {
            let h = MacWritingEngine.analyze(text, harper: engine).suggestions.map { "\($0.original)→\($0.replacement ?? "-") [\($0.title)]" }
            let a = MacWritingEngine.analyze(text, harper: nil).suggestions.map { "\($0.original)→\($0.replacement ?? "-") [\($0.title)]" }
            Self.report("errors_text_\(i)", ["harper": h, "apple": a])
        }
        for (i, text) in (Self.corpus["clean"]! + Self.corpus["chat"]!).enumerated() {
            let h = (engine.lint(text) ?? []).map { "\($0.original) [\($0.title)]" }
            if !h.isEmpty { Self.report("clean_text_\(i)_harper", ["findings": h]) }
        }
    }
}
