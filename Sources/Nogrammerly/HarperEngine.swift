import Foundation

/// Harper (https://github.com/Automattic/harper) as Nogrammerly's deterministic checker: a resident
/// `harper-ls --stdio` sidecar driven over JSON-RPC 2.0 / LSP.
///
/// Why LSP and not a linked library: Harper exposes no C ABI, and its Rust API changes between releases;
/// the language-server protocol is the interface it keeps stable.
///
/// Threading: `lint(_:deadline:)` is synchronous and may be called from the main actor. Writes go out on a serial
/// queue and replies are read on another (`readabilityHandler`), handing results back through semaphores, so a
/// caller only ever waits on a semaphore with its deadline, never on the pipe. Lint calls are serialized.
final class HarperEngine: @unchecked Sendable {
    // MARK: Backend selection

    enum Backend: String { case harper, apple }

    /// `NOGRAMMERLY_ENGINE=harper|apple` in the environment, or `defaults write com.nogrammerly.app NogrammerlyEngine
    /// apple` (the environment does not reach an app opened through LaunchServices, e.g. `open` or the Dock).
    /// Default: harper when a harper-ls executable resolves, else apple.
    static let selection: (backend: Backend, executable: URL?, reason: String) = {
        let env = ProcessInfo.processInfo.environment
        let requested = (env["NOGRAMMERLY_ENGINE"] ?? UserDefaults.standard.string(forKey: "NogrammerlyEngine"))
            .flatMap { Backend(rawValue: $0.lowercased()) }
        if requested == .apple { return (.apple, nil, "Checks: Apple spelling and grammar (engine set to apple)") }
        guard let executable = resolveExecutable(environment: env) else {
            return (.apple, nil, "Checks: Apple spelling and grammar. Harper (harper-ls) was not found, so the built-in checker is used.")
        }
        return (.harper, executable, "Checks: Harper \(pinnedVersion), on this Mac")
    }()

    /// The shared sidecar, or nil when the Apple backend is selected.
    static let shared: HarperEngine? = selection.executable.map { HarperEngine(executable: $0) }

    static let pinnedVersion = "3.2.0"

    /// `HARPER_LS_PATH` (development override), then the copy bundled at Contents/Helpers/harper-ls.
    static func resolveExecutable(environment: [String: String], bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        if let path = environment["HARPER_LS_PATH"], !path.isEmpty {
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/harper-ls")
        return fm.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    // MARK: Status

    static let statusDidChange = Notification.Name("HarperEngineStatusDidChange")
    /// Posted when the sidecar becomes ready, so fields analysed with the Apple fallback meanwhile can be re-checked.
    static let didBecomeReady = Notification.Name("HarperEngineDidBecomeReady")
    private static let statusLock = NSLock()
    /// Notifications go out from here, never from the thread that changed state: a queue-bound observer makes
    /// `post` wait for it, and that thread may hold `lintLock` while the main thread is waiting for the lock.
    private static let notificationQueue = DispatchQueue(label: "nogrammerly.harper.notifications")
    private static func post(_ name: Notification.Name, object: Any? = nil) {
        notificationQueue.async { NotificationCenter.default.post(name: name, object: object) }
    }
    nonisolated(unsafe) private static var _status = selection.reason
    /// One visible line describing which checker is running. The app shows it; fallbacks are never silent.
    static var status: String {
        get { statusLock.lock(); defer { statusLock.unlock() }; return _status }
        set {
            statusLock.lock(); let changed = _status != newValue; _status = newValue; statusLock.unlock()
            if changed { post(statusDidChange) }
        }
    }

    // MARK: Configuration

    /// `publishDiagnostics` carries no version, so each chunk is sent as its own document (focused-1.txt,
    /// focused-2.txt…, the previous one closed first, so the server holds one at a time) and only a publish for that
    /// exact URI answers it. A late or duplicate publish names an older URI and is dropped; it can never be read as the
    /// answer for different text.
    static func documentURI(_ generation: Int) -> String { "file:///nogrammerly/focused-\(generation).txt" }
    /// Frames larger than this are treated as corrupt (a 20,000-character field produces well under 1 MB).
    static let maxFrameBytes = 16 << 20
    /// Plain text, not Markdown: in Markdown mode harper-ls skips `code` spans, but it also title-cases lines that
    /// start with "#", sentence-cases ">" lines and stops checking inside headings, which misfires on chat and mail.
    static let languageID = "plaintext"
    /// Fields are linted in chunks of whole lines of about this many UTF-16 units. harper-ls re-lints the whole
    /// document for every code-action request, so small chunks keep "fetch the fixes" cheap, and an edit only
    /// re-lints the chunk it touched.
    static let chunkTarget = 1_000
    static let chunkHardLimit = 4_000

    /// Default-on harper-ls 3.2.0 rules that rewrite deliberate chat shorthand ("brb" → "be right back", "min" →
    /// "minimum", "ok" → "okay", "gonna" → "going to"). They fire on most Slack-style messages and are switched off.
    /// Generated from `harper-cli config`: every "Expands an initialism" rule, every Expand* rule, Gonna/Gotta/Wanna, OkToOkay,
    /// plus OrthographicConsistency, which recases chat shorthand to "OK", "FYI", "BTW" even when it is in the dictionary.
    static let disabledRules: [String] = [
        "OrthographicConsistency",
        "AsFarAsICanTell", "AsFarAsIKnow", "AsIUnderstandIt", "BeRightBack", "ByTheWay", "ExpandAlgorithm",
        "ExpandAlloc", "ExpandArgument", "ExpandBecause", "ExpandConfiguration", "ExpandControl", "ExpandCoordinate",
        "ExpandDecl", "ExpandDependencies", "ExpandDereference", "ExpandDirectory", "ExpandFavourite", "ExpandForward",
        "ExpandGovt", "ExpandIme", "ExpandLegitimate", "ExpandMemoryShorthands", "ExpandMinimum", "ExpandNotification",
        "ExpandParameter", "ExpandPeople", "ExpandPerformance", "ExpandPointer", "ExpandPreference", "ExpandPrevious",
        "ExpandStandardInputAndOutput", "ExpandThough", "ExpandThrough", "ExpandTimeShorthands", "ExpandVulnerability",
        "ExpandWith", "ExpandWithout", "ExplainLikeImFive", "ForWhatItsWorth", "ForYourInformation", "Gonna", "Gotta",
        "IDontKnow", "IfIRecallCorrectly", "IfIUnderstandCorrectly", "IfYouKnowYouKnow", "InCaseYouMissedIt",
        "InMyHumbleOpinion", "InMyOpinion", "InRealLife", "LetMeKnow", "NeverMind", "OhMyGod", "OkToOkay",
        "OnTheOtherHand", "OutOfTheBox", "PleaseTakeALook", "Really", "TalkToYouLater", "ToBeFair", "ToBeHonest",
        "Wanna"
    ]

    /// Chat shorthand accepted as correctly spelled (Harper's workspace dictionary; the user dictionary stays the user's).
    static let chatWords: [String] = [
        "afaik", "afk", "asap", "bc", "brb", "btw", "dm", "dms", "eod", "eow", "fwiw", "fyi", "gm", "gn", "idk", "iirc",
        "ikr", "imho", "imo", "irl", "jk", "lgtm", "lmao", "lmk", "lol", "nbd", "np", "nvm", "ofc", "omw", "ooo", "pls",
        "plz", "ptal", "rn", "smh", "tbh", "thx", "tmr", "tmrw", "ttyl", "ty", "tysm", "wfh", "wip", "ok", "thu",
        "thurs", "tues", "esp"
    ]

    let executable: URL
    let settings: [String: Any]

    init(executable: URL, support: URL? = HarperEngine.defaultSupportFolder) {
        self.executable = executable
        var options: [String: Any] = [
            "diagnosticDelayMs": 0,
            "maxFileLength": WritingEngine.maxLength,
            "isolateEnglish": false,
            "dialect": HarperEngine.dialect(for: Locale.current),
            // Not "codeActions.ForceStable": it moves commands first and sorts fixes alphabetically, so Harper's best fix
            // stops being the first one. Default order is fixes (best first), then that lint's commands.
            "linters": Dictionary(uniqueKeysWithValues: HarperEngine.disabledRules.map { ($0, false) })
        ]
        // harper-ls otherwise writes into the shared ~/Library/Application Support/harper-ls (also used by editor
        // plugins): keep Nogrammerly's dictionary, ignore list and (unused) stats file in its own folder.
        if let support {
            try? FileManager.default.createDirectory(at: support.appendingPathComponent("ignored-lints"), withIntermediateDirectories: true)
            let chat = support.appendingPathComponent("chat-words.txt")
            try? (HarperEngine.chatWords.joined(separator: "\n") + "\n").write(to: chat, atomically: true, encoding: .utf8)
            options["workspaceDictPath"] = chat.path
            options["userDictPath"] = support.appendingPathComponent("dictionary.txt").path
            options["ignoredLintsPath"] = support.appendingPathComponent("ignored-lints").path
            options["statsPath"] = support.appendingPathComponent("stats.txt").path
        }
        settings = ["harper-ls": options]
    }

    /// ~/Library/Application Support/Nogrammerly/Harper
    static var defaultSupportFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nogrammerly/Harper", isDirectory: true)
    }

    static func dialect(for locale: Locale) -> String {
        switch locale.region?.identifier {
        case "GB", "IE": "British"
        case "AU", "NZ": "Australian"
        case "CA": "Canadian"
        default: "American"
        }
    }

    // MARK: Process state (guarded by `state`)

    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Any?
    }

    private let state = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var waiters: [Int: Waiter] = [:]
    private var diagnosticsWaiter: Waiter?
    private var stopping = false
    private var restartsLeft = 1
    private var uriGeneration = 0
    private var currentURI: String { Self.documentURI(uriGeneration) }
    private var ready = false
    private var starting = false
    /// Serial: keeps frames in order and keeps every caller off the pipe (a full pipe blocks the writer, not them).
    private let writeQueue = DispatchQueue(label: "nogrammerly.harper.write")

    // Serializes lint calls and owns the fields below.
    private let lintLock = NSLock()
    private var openURI: String?
    private var cache: [String: [WritingSuggestion]] = [:]
    private var cacheOrder: [String] = []

    var isRunning: Bool { state.lock(); defer { state.unlock() }; return process?.isRunning == true && ready }
    /// Whether the most recent lint() call answered (false when it fell back). For tests and the benchmark.
    private(set) var lastLintSucceeded = false
    var processIdentifier: Int32? { state.lock(); defer { state.unlock() }; return process?.processIdentifier }

    // MARK: Lifecycle

    /// Spawns harper-ls, performs the LSP handshake and warms the dictionary. Safe to call repeatedly.
    @discardableResult
    func start(timeout: TimeInterval = 5) -> Bool {
        // Flag the start before taking the lock, so a lint() that has not got the lock yet backs off immediately.
        state.lock(); starting = true; state.unlock()
        defer { state.lock(); starting = false; state.unlock() }
        guard lintLock.lock(before: Date(timeIntervalSinceNow: timeout)) else { return false }
        defer { lintLock.unlock() }
        return startLocked(deadline: Date(timeIntervalSinceNow: timeout))
    }

    private func startLocked(deadline: Date) -> Bool {
        if isRunning { return true }
        Self.status = "Checks: Harper is starting; Apple spelling and grammar until it is ready."
        signal(SIGPIPE, SIG_IGN) // a write to a dead sidecar must fail with EPIPE, not kill the app
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--stdio"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] exited in self?.processDidExit(exited) }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        state.lock()
        stopping = false; ready = false; buffer = Data(); uriGeneration = 0
        self.process = process
        input = stdin.fileHandleForWriting
        state.unlock()
        do { try process.run() } catch {
            Self.status = "Checks: Apple spelling and grammar. Harper could not start (\(error.localizedDescription))."
            return false
        }
        openURI = nil
        cache.removeAll(); cacheOrder.removeAll()
        let initialize: [String: Any] = [
            "processId": Int(getpid()),
            "rootUri": NSNull(),
            "clientInfo": ["name": "Nogrammerly"],
            "capabilities": ["workspace": ["configuration": true], "textDocument": ["publishDiagnostics": [:], "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix"]]]]]],
            "initializationOptions": settings
        ]
        guard request("initialize", initialize, deadline: deadline) != nil else {
            Self.status = "Checks: Apple spelling and grammar. Harper did not answer at startup."
            terminate(process)
            return false
        }
        notify("initialized", [:])
        // The first document loads Harper's dictionary (~0.2 s); do it now instead of on the first keystroke.
        _ = lintChunk("Nogrammerly is ready.", deadline: deadline)
        // Ready only now, and `starting` cleared first, so a caller that sees isRunning is never turned away.
        state.lock(); starting = false; ready = self.process?.isRunning == true; let isReady = ready; state.unlock()
        guard isReady else { return false }
        Self.status = Self.selection.reason
        Self.post(Self.didBecomeReady, object: self)
        return true
    }

    /// Shuts the sidecar down: LSP shutdown/exit, then SIGTERM, then SIGKILL. harper-ls also exits on its own
    /// when its stdin closes, so it cannot outlive the app even if the app is killed.
    func stop(timeout: TimeInterval = 1) {
        state.lock()
        stopping = true
        let process = self.process
        state.unlock()
        guard let process, process.isRunning else { return }
        _ = request("shutdown", nil, deadline: Date(timeIntervalSinceNow: timeout / 2))
        notify("exit", nil)
        terminate(process, grace: timeout)
    }

    private func terminate(_ process: Process, grace: TimeInterval = 1) {
        state.lock(); try? input?.close(); input = nil; state.unlock()
        let deadline = Date(timeIntervalSinceNow: grace)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() } // SIGTERM
        let killDeadline = Date(timeIntervalSinceNow: grace)
        while process.isRunning, Date() < killDeadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func processDidExit(_ exited: Process) {
        state.lock()
        guard exited === process else { state.unlock(); return }
        let expected = stopping
        process = nil; input = nil; ready = false
        for waiter in waiters.values { waiter.semaphore.signal() }
        waiters.removeAll()
        diagnosticsWaiter?.semaphore.signal(); diagnosticsWaiter = nil
        let restart = !expected && restartsLeft > 0
        if restart { restartsLeft -= 1 }
        state.unlock()
        guard !expected else { return }
        if restart {
            Self.status = "Checks: Harper stopped unexpectedly (exit \(exited.terminationStatus)); restarting…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.start() }
        } else {
            Self.status = "Checks: Apple spelling and grammar. Harper stopped twice (exit \(exited.terminationStatus)), so it was not restarted."
        }
    }

    // MARK: Linting

    /// Lints `text` and returns suggestions with ranges in `text`, or nil when Harper is starting, stopped or
    /// missed `deadline` (the caller then falls back to the Apple checker for this pass). Never spawns the
    /// sidecar itself and never waits for a start in progress, so a main-thread caller is not held up by one.
    func lint(_ text: String, deadline: Date = Date(timeIntervalSinceNow: 1)) -> [WritingSuggestion]? {
        lastLintSucceeded = false
        // Take the lock without ever waiting behind a start: poll it, and give up as soon as a start is flagged.
        while !lintLock.try() {
            state.lock(); let busyStarting = starting; state.unlock()
            if busyStarting { return nil }
            if Date() >= deadline {
                Self.status = "Checks: Apple spelling and grammar for now. Harper was busy."
                return nil
            }
            usleep(1_000)
        }
        defer { lintLock.unlock() }
        guard isRunning else { return nil }
        let nsText = text as NSString
        var results: [WritingSuggestion] = []
        for chunkRange in Self.chunks(of: nsText) {
            let chunk = nsText.substring(with: chunkRange)
            guard chunk.contains(where: { !$0.isWhitespace }) else { continue }
            let found: [WritingSuggestion]
            if let cached = cache[chunk] {
                found = cached
            } else {
                guard let fresh = lintChunk(chunk, deadline: deadline) else { return nil }
                // A chunk whose fixes missed the deadline is shown as is but not cached, so the next pass retries it.
                if fresh.complete { remember(fresh.suggestions, for: chunk) }
                found = fresh.suggestions
            }
            results += found.map { $0.shifted(by: chunkRange.location) }
        }
        lastLintSucceeded = true
        if isRunning { Self.status = Self.selection.reason } // never paper over a stop reported meanwhile
        return results
    }

    /// Sends one chunk as its own document, waits for its diagnostics, then fetches the fixes. `complete` is false when
    /// some fixes missed the deadline (those suggestions have no replacement).
    private func lintChunk(_ text: String, deadline: Date) -> (suggestions: [WritingSuggestion], complete: Bool)? {
        retireDocument()
        let waiter = Waiter()
        state.lock(); diagnosticsWaiter = waiter; let uri = currentURI; state.unlock()
        notify("textDocument/didOpen", ["textDocument": ["uri": uri, "languageId": Self.languageID, "version": 1, "text": text]])
        openURI = uri
        guard waiter.semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success,
              let diagnostics = waiter.value as? [[String: Any]] else {
            retireDocument() // a late answer will name this URI and be dropped
            Self.status = "Checks: Apple spelling and grammar for now. Harper did not answer in time."
            return nil
        }
        // Pipeline every code-action request, then collect; a fix that misses the deadline only loses its replacement.
        let nsText = text as NSString
        let starts = HarperMapper.lineStarts(of: nsText)
        let ids = diagnostics.map { diagnostic in
            let range = HarperMapper.codeActionRange(for: diagnostic["range"] as? [String: Any], in: nsText, lineStarts: starts) ?? [:]
            return send(request: "textDocument/codeAction", ["textDocument": ["uri": uri], "range": range, "context": ["diagnostics": [diagnostic]]])
        }
        let actions = ids.map { id in id.flatMap { collect($0, deadline: deadline) } as? [[String: Any]] }
        return (HarperMapper.map(diagnostics: diagnostics, actions: actions, in: text), !actions.contains { $0 == nil })
    }

    /// Closes the open document (if any) and moves to a fresh URI, so any publish still in flight is dropped.
    /// Caller holds lintLock.
    private func retireDocument() {
        if let openURI { notify("textDocument/didClose", ["textDocument": ["uri": openURI]]) }
        openURI = nil
        state.lock(); diagnosticsWaiter = nil; uriGeneration += 1; state.unlock()
    }

    private func remember(_ found: [WritingSuggestion], for chunk: String) {
        cache[chunk] = found
        cacheOrder.append(chunk)
        if cacheOrder.count > 512 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Splits at line boundaries: prefer a blank line once a chunk reaches `chunkTarget`, any line at `chunkHardLimit`.
    static func chunks(of text: NSString) -> [NSRange] {
        let starts = HarperMapper.lineStarts(of: text)
        var ranges: [NSRange] = []
        var chunkStart = 0
        for (index, lineStart) in starts.enumerated().dropFirst() {
            let size = lineStart - chunkStart
            let lineIsBlank = text.substring(with: NSRange(location: starts[index - 1], length: lineStart - starts[index - 1]))
                .allSatisfy(\.isWhitespace)
            if (size >= chunkTarget && lineIsBlank) || size >= chunkHardLimit {
                ranges.append(NSRange(location: chunkStart, length: size))
                chunkStart = lineStart
            }
        }
        if chunkStart < text.length || ranges.isEmpty { ranges.append(NSRange(location: chunkStart, length: text.length - chunkStart)) }
        return ranges.flatMap { $0.length > chunkHardLimit ? split(oversized: $0, in: text) : [$0] }
    }

    /// A line longer than `chunkHardLimit` (one huge paragraph): cut at sentence ends, or at whitespace inside an
    /// oversized sentence, never inside a composed character such as an emoji.
    static func split(oversized range: NSRange, in text: NSString) -> [NSRange] {
        var cuts: [Int] = []
        text.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            cuts.append(NSMaxRange(enclosing))
        }
        var pieces: [NSRange] = []
        var start = range.location
        var lastCut = start
        func emit(upTo end: Int) { pieces.append(NSRange(location: start, length: end - start)); start = end; lastCut = end }
        for cut in cuts where cut > start {
            if cut - start > chunkHardLimit, lastCut > start { emit(upTo: lastCut) }
            while cut - start > chunkHardLimit {
                // A single sentence longer than the limit: back off to whitespace, then to a character boundary.
                var end = start + chunkHardLimit
                let window = NSRange(location: start + chunkHardLimit / 2, length: chunkHardLimit / 2)
                let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: window)
                if space.location != NSNotFound { end = NSMaxRange(space) }
                else { end = text.rangeOfComposedCharacterSequence(at: end).location }
                emit(upTo: end)
            }
            lastCut = cut
        }
        if start < NSMaxRange(range) { pieces.append(NSRange(location: start, length: NSMaxRange(range) - start)) }
        return pieces
    }

    // MARK: Dictionary
    //
    // "Ignore" is not forwarded: in harper-ls 3.2.0 `HarperIgnoreLint` only sticks when ignores are stored in the
    // shared ~/Library/Application Support/harper-ls folder (where they would also persist forever and leak into
    // editors). Nogrammerly's own ignore list, keyed by the Harper rule name and the flagged text, filters them.

    /// Adds a word to Nogrammerly's Harper user dictionary (persisted at `userDictPath`).
    func addToDictionary(_ word: String) {
        execute("HarperAddToUserDict") { [word, $0] }
    }

    private func execute(_ command: String, arguments: (String) -> [Any]) {
        withLintLock {
            guard isRunning else { return }
            // harper-ls re-publishes the open document after a command (response first, then the publish), and may
            // or may not for a closed one. Retire the URI so that publish can never answer the next lint.
            state.lock(); let uri = openURI ?? currentURI; state.unlock()
            _ = request("workspace/executeCommand", ["command": command, "arguments": arguments(uri)], deadline: Date(timeIntervalSinceNow: 1))
            retireDocument()
            cache.removeAll(); cacheOrder.removeAll()
        }
    }

    private func withLintLock<T>(_ body: () -> T) -> T {
        lintLock.lock(); defer { lintLock.unlock() }
        return body()
    }

    // MARK: JSON-RPC transport

    private func request(_ method: String, _ params: Any?, deadline: Date) -> Any? {
        send(request: method, params).flatMap { collect($0, deadline: deadline) }
    }

    /// Writes a request and registers its waiter; returns the id, or nil if the pipe is gone.
    private func send(request method: String, _ params: Any?) -> Int? {
        state.lock()
        nextID += 1
        let id = nextID
        waiters[id] = Waiter()
        state.unlock()
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        guard write(message) else { state.lock(); waiters[id] = nil; state.unlock(); return nil }
        return id
    }

    /// Waits for the response to `id`; nil on timeout, error or exit.
    private func collect(_ id: Int, deadline: Date) -> Any? {
        state.lock(); let waiter = waiters[id]; state.unlock()
        guard let waiter else { return nil }
        let answered = waiter.semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
        state.lock(); waiters[id] = nil; state.unlock()
        return answered ? waiter.value : nil
    }

    private func notify(_ method: String, _ params: Any?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        write(message)
    }

    /// Queues a frame for the sidecar. Never blocks the caller and never holds `state` across pipe I/O: if
    /// harper-ls stops reading, only the write queue waits, and callers still hit their deadlines.
    @discardableResult
    private func write(_ message: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        state.lock(); let input = self.input; state.unlock()
        guard let input else { return false }
        writeQueue.async { try? input.write(contentsOf: frame) } // EPIPE after an exit is reported by processDidExit
        return true
    }

    private func receive(_ data: Data) {
        state.lock()
        buffer.append(data)
        let messages = Self.takeFrames(from: &buffer)
        state.unlock()
        messages.forEach(handle)
    }

    /// Content-Length framing: removes every complete frame from `buffer` and returns the decoded messages. A header
    /// without a valid length (missing, non-numeric, negative or over `maxFrameBytes`) is skipped, never trusted.
    static func takeFrames(from buffer: inout Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").lazy.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first
            guard let length, (0...maxFrameBytes).contains(length) else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound) // malformed header: drop it, keep reading
                continue
            }
            guard buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: length)
            if let message = try? JSONSerialization.jsonObject(with: buffer[headerEnd.upperBound..<bodyEnd]) as? [String: Any] {
                messages.append(message)
            }
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return messages
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        if let id = message["id"], let method {
            // Server → client request.
            var result: Any = NSNull()
            if method == "workspace/configuration" {
                let items = (message["params"] as? [String: Any])?["items"] as? [Any] ?? [[:]]
                result = Array(repeating: settings, count: items.count) // harper-ls wants the object holding "harper-ls"
            }
            write(["jsonrpc": "2.0", "id": id, "result": result])
        } else if let id = message["id"] as? Int {
            state.lock()
            if let waiter = waiters[id] {
                waiter.value = message["error"] == nil ? (message["result"] ?? NSNull()) : nil
                waiter.semaphore.signal()
            }
            state.unlock()
        } else if method == "textDocument/publishDiagnostics",
                  let params = message["params"] as? [String: Any] {
            state.lock()
            // Only a publish for the document just sent answers it; anything else is late or duplicate: drop it.
            if params["uri"] as? String == currentURI, let waiter = diagnosticsWaiter {
                diagnosticsWaiter = nil
                waiter.value = params["diagnostics"] as? [[String: Any]] ?? []
                waiter.semaphore.signal()
            }
            state.unlock()
        }
    }
}

extension WritingSuggestion {
    func shifted(by offset: Int) -> WritingSuggestion {
        WritingSuggestion(kind: kind, title: title, explanation: explanation, original: original, replacement: replacement,
                          range: NSRange(location: range.location + offset, length: range.length), isSpelling: isSpelling)
    }
}
