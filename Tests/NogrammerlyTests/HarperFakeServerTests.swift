import Foundation
import Testing
@testable import Nogrammerly

/// HarperEngine against a scripted stand-in for harper-ls (Fixtures/fake-harper-ls.py), so races that depend on
/// when the server answers are tested deterministically instead of by sleeping. Needs python3 only.
enum FakeHarper {
    static let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static var available: Bool { python != nil }

    /// An executable wrapper that starts the fake server in `mode` (HarperEngine passes `--stdio` to it).
    static func executable(_ mode: String) throws -> URL {
        let script = try #require(Bundle.module.url(forResource: "fake-harper-ls", withExtension: "py", subdirectory: "Fixtures"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fake-harper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wrapper = folder.appendingPathComponent("harper-ls")
        try "#!/bin/sh\nexec \"\(try #require(python))\" \"\(script.path)\" \(mode) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    static func engine(_ mode: String) throws -> HarperEngine {
        HarperEngine(executable: try executable(mode),
                     support: FileManager.default.temporaryDirectory.appendingPathComponent("nogrammerly-fake-\(UUID().uuidString)", isDirectory: true))
    }
}

@Suite(.serialized, .enabled(if: FakeHarper.available, "python3 not found"))
struct HarperFakeServerTests {
    /// A publish that arrives after its deadline, while the next document is waiting, must not answer it.
    @Test func latePublishNeverAnswersNewerText() throws {
        let engine = try FakeHarper.engine("late-publish"); defer { engine.stop() }
        try #require(engine.start(timeout: HarperTestSupport.patience))
        #expect(engine.lint("WITHHOLD teh", deadline: Date(timeIntervalSinceNow: 0.3)) == nil)
        // The server now sends the withheld "teh" diagnostic right before this document's own (empty) answer.
        #expect(try #require(engine.lint("Clean text here.", deadline: HarperTestSupport.patient())).isEmpty)
        let next = try #require(engine.lint("Look at teh numbers.", deadline: HarperTestSupport.patient()))
        #expect(next.map(\.original) == ["teh"] && next.first?.range == NSRange(location: 8, length: 3))
    }

    /// While the sidecar is starting, lint() answers at once (Apple fallback) instead of holding up its caller.
    @Test func lintReturnsAtOnceWhileStarting() throws {
        let engine = try FakeHarper.engine("slow-init"); defer { engine.stop() }
        let ready = Locked(false)
        let observer = NotificationCenter.default.addObserver(forName: HarperEngine.didBecomeReady, object: engine, queue: nil) { _ in ready.set(true) }
        defer { NotificationCenter.default.removeObserver(observer) }
        DispatchQueue.global().async { engine.start(timeout: HarperTestSupport.patience) }
        #expect(HarperTestSupport.waitUntil(5) { engine.processIdentifier != nil })
        let start = Date()
        #expect(engine.lint("Look at teh numbers.") == nil) // initialize takes 1.5 s: still starting
        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(HarperTestSupport.waitUntil(HarperTestSupport.patience) { engine.isRunning })
        #expect(HarperTestSupport.waitUntil(1) { ready.get() })
        #expect(engine.lint("Look at teh numbers.", deadline: HarperTestSupport.patient())?.map(\.original) == ["teh"])
    }

    /// An observer that checks text as soon as Harper is ready (as the app does) must get Harper's answer, not wait
    /// for a lock the engine holds while it announces readiness.
    @Test func readyObserverCanLintImmediately() throws {
        let engine = try FakeHarper.engine("normal"); defer { engine.stop() }
        let answer = Locked<[String]?>(nil)
        let elapsed = Locked<TimeInterval>(-1)
        let queue = OperationQueue()
        let observer = NotificationCenter.default.addObserver(forName: HarperEngine.didBecomeReady, object: engine, queue: queue) { _ in
            let start = Date()
            answer.set(engine.lint("Look at teh numbers.")?.map(\.original))
            elapsed.set(Date().timeIntervalSince(start))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try #require(engine.start(timeout: HarperTestSupport.patience))
        #expect(HarperTestSupport.waitUntil(5) { elapsed.get() >= 0 })
        #expect(answer.get() == ["teh"])
        #expect(elapsed.get() < 0.5)
    }

    /// Fixes that miss the deadline leave the finding without a replacement for that pass, and are not cached.
    @Test func incompleteFixesAreRetriedNotCached() throws {
        let engine = try FakeHarper.engine("slow-actions"); defer { engine.stop() }
        try #require(engine.start(timeout: HarperTestSupport.patience))
        let text = "SLOW teh"
        let first = try #require(engine.lint(text, deadline: Date(timeIntervalSinceNow: 0.3)))
        #expect(first.map(\.original) == ["teh"] && first.first?.replacement == nil)
        let second = try #require(engine.lint(text, deadline: HarperTestSupport.patient()))
        #expect(second.first?.replacement == "the")
    }
}

/// A tiny thread-safe box for values set from notification callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

@Suite struct HarperTransportTests {
    static func frame(_ json: String) -> Data { Data("Content-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8) }

    @Test func malformedHeadersAreSkippedNotFatal() {
        var buffer = Data("Content-Length:\r\n\r\n".utf8)              // no value (used to crash)
        buffer += Data("Content-Length: -5\r\n\r\n".utf8)              // negative
        buffer += Data("Content-Length: abc\r\n\r\n".utf8)             // not a number
        buffer += Data("Content-Length: 99999999999\r\n\r\n".utf8)     // absurdly large
        buffer += Data("X-Other: 1\r\n\r\n".utf8)                      // no length at all
        buffer += Self.frame(#"{"jsonrpc":"2.0","id":1,"result":null}"#)
        let messages = HarperEngine.takeFrames(from: &buffer)
        #expect(messages.count == 1 && messages.first?["id"] as? Int == 1)
        #expect(buffer.isEmpty)
    }

    @Test func partialFrameWaitsForTheRest() {
        let whole = Self.frame(#"{"jsonrpc":"2.0","method":"x"}"#) + Self.frame(#"{"jsonrpc":"2.0","method":"y"}"#)
        var buffer = whole.prefix(whole.count - 5)
        #expect(HarperEngine.takeFrames(from: &buffer).map { $0["method"] as? String } == ["x"])
        buffer += whole.suffix(5)
        #expect(HarperEngine.takeFrames(from: &buffer).map { $0["method"] as? String } == ["y"])
        #expect(buffer.isEmpty)
    }

    @Test func longLinesSplitAtSentencesWithinTheLimit() {
        let sentence = "This sentence is part of one very long paragraph without a single line break. " // 79 units
        let text = String(repeating: sentence, count: 150) as NSString // 11,850 units on one line
        let chunks = HarperEngine.chunks(of: text)
        #expect(chunks.count > 2)
        #expect(chunks.reduce(0) { $0 + $1.length } == text.length)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        for chunk in chunks {
            #expect(chunk.length <= HarperEngine.chunkHardLimit)
            #expect(text.substring(with: chunk).hasPrefix("This sentence")) // every cut is at a sentence start
        }
    }

    @Test func unbreakableRunNeverSplitsAnEmoji() {
        let text = String(repeating: "a👍🏽", count: 2_000) as NSString // 10,000 units, no whitespace or sentence end
        let chunks = HarperEngine.chunks(of: text)
        #expect(chunks.reduce(0) { $0 + $1.length } == text.length)
        for chunk in chunks {
            #expect(chunk.length <= HarperEngine.chunkHardLimit)
            #expect(text.rangeOfComposedCharacterSequence(at: chunk.location).location == chunk.location)
        }
    }
}
