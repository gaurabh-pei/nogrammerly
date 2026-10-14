import AppKit
import ApplicationServices

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private let editor = NSTextView()
    private let suggestionTable = NSTableView()
    private let scoreLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let rewriteButton = NSButton()
    private let everywhereButton = NSButton(title: "", target: nil, action: nil)
    private let everywhereStatus = NSTextField(labelWithString: "")
    private let toneControl = NSSegmentedControl(labels: WritingTone.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private var suggestions: [WritingSuggestion] = []
    private var proofreadTask: Task<Void, Never>?
    private let systemAssistant = SystemWritingAssistant()
    private lazy var setup = SetupWindowController(assistant: systemAssistant)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        AIWriter.prewarm()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Nogrammerly"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = makeInterface()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.string = "Hello team,\n\nI wanted to recieve your feedback on the proposal. We utilize the new workflow in order to make our approvals faster, and I think it will be very helpful!!\n\nThank you"
        systemAssistant.onStateChange = { [weak self] message in
            self?.statusLabel.stringValue = message
            self?.updateEverywhereControls()
        }
        systemAssistant.onOpenApp = { [weak self] in self?.showWindow() }
        systemAssistant.onOpenSetup = { [weak self] in self?.showSetup() }
        refreshAnalysis()
        if AXIsProcessTrusted() {
            systemAssistant.start()
        } else {
            DispatchQueue.main.async { [weak self] in self?.showSetup() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeInterface() -> NSView {
        let root = NSView(); root.wantsLayer = true
        let sidebar = makeSidebar(); let workspace = makeWorkspace(); let assistant = makeAssistant()
        let stack = NSStackView(views: [sidebar, workspace, assistant]); stack.orientation = .horizontal; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor), stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 225), assistant.widthAnchor.constraint(equalToConstant: 340)])
        return root
    }

    private func makeSidebar() -> NSView {
        let panel = NSView(); panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let logo = NSTextField(labelWithString: "✦  Nogrammerly"); logo.font = .systemFont(ofSize: 17, weight: .bold); logo.textColor = .systemIndigo
        let newDoc = NSButton(title: "+  New document", target: self, action: #selector(newDocument)); newDoc.bezelColor = .systemIndigo
        everywhereStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        everywhereButton.target = self; everywhereButton.action = #selector(everywhereButtonClicked); everywhereButton.bezelColor = .systemIndigo
        updateEverywhereControls()
        let engine = NSTextField(wrappingLabelWithString: AIWriter.isAvailable ? "✦  AI checks: Apple on-device model" : "✦  AI checks off: turn on Apple Intelligence in System Settings for grammar, tone and rewrites."); engine.textColor = .secondaryLabelColor; engine.font = .systemFont(ofSize: 12)
        let privacy = NSTextField(wrappingLabelWithString: "◎  Everywhere mode checks your writing in Slack, Notes, Zoom and most other apps. Click the round button in the corner of the field you're typing in, or right-click an underline. Your text stays on this Mac."); privacy.textColor = .secondaryLabelColor; privacy.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [logo, newDoc, NSView(), everywhereStatus, everywhereButton, engine, privacy]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -22), newDoc.widthAnchor.constraint(equalTo: stack.widthAnchor), everywhereButton.widthAnchor.constraint(equalTo: stack.widthAnchor), privacy.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        return panel
    }

    private func makeWorkspace() -> NSView {
        let panel = NSView()
        let title = NSTextField(labelWithString: "Document"); title.font = .systemFont(ofSize: 17, weight: .bold)
        statusLabel.stringValue = "Saved locally"; statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        let titleStack = NSStackView(views: [title, statusLabel]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 3
        rewriteButton.title = "✦ Rewrite"; rewriteButton.bezelStyle = .rounded; rewriteButton.target = self; rewriteButton.action = #selector(rewrite); rewriteButton.bezelColor = .systemIndigo
        let toolbar = NSStackView(views: [titleStack, NSView(), rewriteButton]); toolbar.orientation = .horizontal; toolbar.alignment = .centerY
        editor.font = .systemFont(ofSize: 17); editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isContinuousSpellCheckingEnabled = false; editor.allowsUndo = true; editor.delegate = self; editor.textContainerInset = NSSize(width: 34, height: 28)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let stack = NSStackView(views: [toolbar, scroll]); stack.orientation = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18), scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 480), toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        return panel
    }

    private func makeAssistant() -> NSView {
        let panel = NSView(); panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let title = NSTextField(labelWithString: "Writing assistant"); title.font = .systemFont(ofSize: 16, weight: .bold)
        toneControl.selectedSegment = 0
        let toneHint = NSTextField(labelWithString: "Tone used by ✦ Rewrite"); toneHint.font = .systemFont(ofSize: 11); toneHint.textColor = .secondaryLabelColor
        scoreLabel.font = .systemFont(ofSize: 14, weight: .semibold); scoreLabel.maximumNumberOfLines = 2
        let hint = NSTextField(labelWithString: "Click a suggestion to apply it."); hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion")); column.width = 300; suggestionTable.addTableColumn(column); suggestionTable.headerView = nil; suggestionTable.delegate = self; suggestionTable.dataSource = self; suggestionTable.rowHeight = 92
        let list = NSScrollView(); list.documentView = suggestionTable; list.hasVerticalScroller = true; list.borderType = .noBorder
        let stack = NSStackView(views: [title, toneControl, toneHint, scoreLabel, hint, list]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18), toneControl.widthAnchor.constraint(equalTo: stack.widthAnchor), list.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        return panel
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = suggestions[row]
        let cell = NSTextField(wrappingLabelWithString: "\(s.kind.rawValue.uppercased())  •  \(s.title)\n\(s.explanation)\(s.replacement.map { "\nChange to ‘\($0)’" } ?? "\nClick to select")")
        cell.font = .systemFont(ofSize: 12); cell.textColor = .labelColor; cell.maximumNumberOfLines = 4
        let bar = NSView(); bar.wantsLayer = true; bar.layer?.backgroundColor = s.kind.color.cgColor
        let stack = NSStackView(views: [bar, cell]); stack.spacing = 8
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = suggestionTable.selectedRow
        guard row >= 0 else { return }
        let suggestion = suggestions[row]
        let nsText = editor.string as NSString
        guard NSMaxRange(suggestion.range) <= nsText.length, nsText.substring(with: suggestion.range) == suggestion.original else { refreshAnalysis(); return }
        if let replacement = suggestion.replacement, editor.shouldChangeText(in: suggestion.range, replacementString: replacement) {
            editor.replaceCharacters(in: suggestion.range, with: replacement)
            editor.didChangeText()
        } else {
            editor.setSelectedRange(suggestion.range)
            editor.scrollRangeToVisible(suggestion.range)
            window.makeFirstResponder(editor)
        }
    }

    func textDidChange(_ notification: Notification) { refreshAnalysis() }

    @objc private func newDocument() { editor.string = ""; refreshAnalysis() }
    /// The sidebar control mirrors everywhere mode: set up permissions, turn it on, or pause it.
    private func updateEverywhereControls() {
        if !AXIsProcessTrusted() {
            everywhereStatus.stringValue = "●  Everywhere mode: needs permission"; everywhereStatus.textColor = .systemOrange
            everywhereButton.title = "Set Up Permissions…"
        } else if systemAssistant.isRunning {
            everywhereStatus.stringValue = "●  Everywhere mode: on"; everywhereStatus.textColor = .systemGreen
            everywhereButton.title = "Pause Everywhere Mode"
        } else {
            everywhereStatus.stringValue = "●  Everywhere mode: paused"; everywhereStatus.textColor = .secondaryLabelColor
            everywhereButton.title = "Turn On Everywhere Mode"
        }
    }

    @objc private func everywhereButtonClicked() {
        if !AXIsProcessTrusted() { systemAssistant.start(); showSetup() }
        else if systemAssistant.isRunning { systemAssistant.stop() }
        else { systemAssistant.start() }
        updateEverywhereControls()
    }

    @objc private func showSetup() { setup.present() }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        submenu("Nogrammerly", [
            item("About Nogrammerly", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Setup Guide…", #selector(showSetup), target: self),
            .separator(),
            item("Hide Nogrammerly", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Nogrammerly", #selector(NSApplication.terminate(_:)), "q")
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a")
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Show Nogrammerly", #selector(showMainWindow), "0", target: self)
        ])
        submenu("Help", [item("Nogrammerly Setup Guide", #selector(showSetup), "?", target: self)])
        return main
    }

    @objc private func showMainWindow() { showWindow() }

    @objc private func rewrite() {
        let tone = WritingTone.allCases[max(0, toneControl.selectedSegment)]
        let original = editor.string
        rewriteButton.isEnabled = false
        statusLabel.stringValue = "Rewriting in a \(tone.rawValue.lowercased()) tone…"
        Task { [weak self] in
            let rewritten = await AIWriter.rewrite(original, tone: tone) ?? WritingEngine.rewrite(original, tone: tone)
            guard let self else { return }
            self.rewriteButton.isEnabled = true
            guard self.editor.string == original else { self.statusLabel.stringValue = "Text changed while rewriting; rewrite discarded."; return }
            let all = NSRange(location: 0, length: (original as NSString).length)
            if self.editor.shouldChangeText(in: all, replacementString: rewritten) {
                self.editor.replaceCharacters(in: all, with: rewritten)
                self.editor.didChangeText()
            }
        }
    }

    private func refreshAnalysis() {
        let text = editor.string
        let result = WritingEngine.analyze(text)
        show(result.suggestions, words: result.words, readability: result.readability, tone: result.tone)
        proofreadTask?.cancel()
        proofreadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            let found = await AIWriter.proofread(text)
            guard let self, !Task.isCancelled, self.editor.string == text, !found.isEmpty else { return }
            self.show(WritingEngine.merge(result.suggestions, found), words: result.words, readability: result.readability, tone: result.tone)
        }
    }

    private func show(_ list: [WritingSuggestion], words: Int, readability: Int, tone: String) {
        suggestions = list
        scoreLabel.stringValue = "Writing score  \(readability)  •  \(words) words\n\(tone) tone  •  \(list.count) suggestions"
        suggestionTable.reloadData()
        guard let layoutManager = editor.layoutManager else { return }
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
        for suggestion in list where NSMaxRange(suggestion.range) <= all.length {
            layoutManager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: suggestion.kind.color], forCharacterRange: suggestion.range)
        }
    }
}
