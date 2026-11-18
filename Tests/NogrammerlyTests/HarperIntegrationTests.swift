import Foundation
import Testing
import NogrammerlyCore
@testable import Nogrammerly

/// Drives the real harper-ls sidecar. Skipped when no binary is available: set HARPER_LS_PATH, or run
/// script/fetch_harper_ls.sh to place the pinned build in Vendor/harper-ls/bin.
enum HarperTestSupport {
    static let executable: URL? = {
        let env = ProcessInfo.processInfo.environment["HARPER_LS_PATH"]
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Vendor/harper-ls/bin/harper-ls").standardized.path
        return [env, vendored].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }()
    /// The pinned binary is arm64 only; on an Intel runner the live tests skip rather than fail.
    static var available: Bool {
        #if arch(arm64)
        return executable != nil
        #else
        return false
        #endif
    }

    /// The app gives Harper 1 s per pass and falls back to Apple when it misses. Tests wait longer so a busy CI
    /// runner does not turn a slow answer into a failure; `recoversAfterMissedDeadline` covers the miss itself.
    static let patience: TimeInterval = 20
    static func patient() -> Date { Date(timeIntervalSinceNow: patience) }

    static func makeEngine() throws -> HarperEngine {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("nogrammerly-test-\(UUID().uuidString)", isDirectory: true)
        let engine = HarperEngine(executable: try #require(executable), support: support)
        try #require(engine.start(timeout: patience))
        return engine
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline { if condition() { return true }; usleep(20_000) }
        return condition()
    }
}

@Suite(.serialized, .enabled(if: HarperTestSupport.available, "harper-ls not found: set HARPER_LS_PATH or run script/fetch_harper_ls.sh"))
struct HarperIntegrationTests {
    @Test func flagsInjectedTypoAsSpelling() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        let text = "Thanks, I wanted to recieve your feedback."
        let found = try #require(engine.lint(text, deadline: HarperTestSupport.patient()))
        let typo = try #require(found.first { $0.original == "recieve" })
        #expect(typo.isSpelling && typo.kind == .correctness)
        #expect(typo.replacement == "receive")
        #expect(typo.range == (text as NSString).range(of: "recieve"))
    }

    @Test func analyzeMergesHarperWithLocalRules() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        let text = "We utilize this tool to recieve data."
        _ = engine.lint(text, deadline: HarperTestSupport.patient()) // warm the chunk cache; analyze() keeps the app's 1 s budget
        let suggestions = MacWritingEngine.analyze(text, harper: engine).suggestions
        #expect(suggestions.contains { $0.original.lowercased() == "utilize" && $0.replacement == "use" }) // local rule
        #expect(suggestions.contains { $0.original == "recieve" && $0.title.hasSuffix("(Harper)") })      // Harper primary
    }

    /// Live check of the harper-ls 3.2.0 code-action range workaround and of chunk offsets after emoji.
    @Test func fixesAfterEmojiLandOnTheRightText() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        let text = "Résumé 👩‍👩‍👧‍👦 done.\n\nGreat work 👍🏽 on teh launch, i think its ready."
        let ns = text as NSString
        let found = try #require(engine.lint(text, deadline: HarperTestSupport.patient()))
        for s in found { #expect(NSMaxRange(s.range) <= ns.length && ns.substring(with: s.range) == s.original) }
        let teh = try #require(found.first { $0.original == "teh" })
        #expect(teh.replacement == "the" && teh.range == ns.range(of: "teh"))
        #expect(found.contains { $0.original == "i" && $0.replacement == "I" })
    }

    @Test func twentyThousandCharactersWithinBudget() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        var text = ""
        var i = 0
        while (text as NSString).length < WritingEngine.maxLength - 200 {
            text += "Paragraph \(i) 😀: we recieve the report and teh team reviews it before Friday.\n\n"; i += 1
        }
        let start = Date()
        let found = try #require(engine.lint(text, deadline: HarperTestSupport.patient()))
        let elapsed = Date().timeIntervalSince(start)
        let ns = text as NSString
        #expect(found.count >= i * 2)
        for item in found { #expect(ns.substring(with: item.range) == item.original) }
        #expect(elapsed < HarperTestSupport.patience) // no stall; latency is measured by HarperBenchmarkTests
    }

    @Test func stopLeavesNoProcess() throws {
        let engine = try HarperTestSupport.makeEngine()
        let pid = try #require(engine.processIdentifier)
        #expect(HarperTestSupport.isAlive(pid))
        engine.stop()
        #expect(HarperTestSupport.waitUntil(2) { !HarperTestSupport.isAlive(pid) })
        #expect(engine.processIdentifier == nil)
    }

    @Test func restartsOnceThenGivesUp() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        let first = try #require(engine.processIdentifier)
        kill(first, SIGKILL)
        #expect(HarperTestSupport.waitUntil(HarperTestSupport.patience) { engine.isRunning && engine.processIdentifier != first })
        #expect(engine.lint("A sentance.", deadline: HarperTestSupport.patient())?.isEmpty == false)
        let second = try #require(engine.processIdentifier)
        kill(second, SIGKILL)
        #expect(HarperTestSupport.waitUntil(2) { engine.processIdentifier == nil })
        usleep(300_000)
        #expect(!engine.isRunning)
        #expect(HarperEngine.status.contains("not restarted"))
    }

    @Test func addToDictionaryReachesHarper() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        let word = "Zorbulate"
        #expect(try #require(engine.lint("Please \(word) the files.", deadline: HarperTestSupport.patient())).contains { $0.original == word })
        engine.addToDictionary(word)
        #expect(try #require(engine.lint("Please \(word) the files.", deadline: HarperTestSupport.patient())).contains { $0.original == word } == false)
        // The publish that the command triggers must not be read as the next answer.
        let next = try #require(engine.lint("Look at teh numbers.", deadline: HarperTestSupport.patient()))
        #expect(next.contains { $0.original == "teh" })
    }

    /// Add to dictionary right after a missed deadline: the command's publish must not answer the next lint.
    @Test func dictionaryAfterMissedDeadline() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        #expect(engine.lint("Please Zorbulate it.", deadline: Date()) == nil)
        engine.addToDictionary("Zorbulate")
        usleep(200_000)
        let found = try #require(engine.lint("Look at teh numbers.", deadline: HarperTestSupport.patient()))
        #expect(found.map(\.original) == ["teh"])
        #expect(try #require(engine.lint("Please Zorbulate it.", deadline: HarperTestSupport.patient())).isEmpty)
    }

    /// A lint that misses its deadline must not poison later ones: the late answer is dropped by URI.
    @Test func recoversAfterMissedDeadline() throws {
        let engine = try HarperTestSupport.makeEngine(); defer { engine.stop() }
        #expect(engine.lint("We recieve it.", deadline: Date()) == nil) // deadline already passed
        usleep(200_000) // let the late publish arrive
        let found = try #require(engine.lint("Look at teh numbers.", deadline: HarperTestSupport.patient()))
        #expect(found.map(\.original) == ["teh"])
    }
}
