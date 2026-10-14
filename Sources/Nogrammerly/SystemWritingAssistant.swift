import AppKit
import ApplicationServices

/// Grammarly-style assistance in other apps: reads the focused text field through the Accessibility API,
/// underlines issues in a click-through overlay, and offers fixes when the user right-clicks an underline.
@MainActor
final class SystemWritingAssistant: NSObject, NSMenuDelegate {
    /// An issue currently drawn on screen; `rect` is in Accessibility (top-left origin) screen coordinates.
    private struct Mark { let suggestion: WritingSuggestion; let rect: CGRect }

    private var pollTimer: Timer?
    private var permissionTimer: Timer?
    private var eventTap: CFMachPort?
    private var swallowNextRightMouseUp = false
    private var element: AXUIElement?
    private var text = ""
    private var suggestions: [WritingSuggestion] = []
    private var marks: [Mark] = []
    private var ignored = Set<String>()
    private var proofreadTask: Task<Void, Never>?
    private let overlay = UnderlineOverlay()
    private lazy var fieldButton = FieldButtonPanel { [weak self] in self?.showFieldMenu() }
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onStateChange: ((String) -> Void)?
    var onOpenApp: (() -> Void)?
    var onOpenSetup: (() -> Void)?

    var isRunning: Bool { pollTimer != nil }

    override init() {
        super.init()
        statusItem.button?.title = "✦"
        statusItem.button?.toolTip = "Nogrammerly"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func start() {
        guard !isRunning else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            report("Waiting for Accessibility access: System Settings › Privacy & Security › Accessibility. If Nogrammerly is already listed, remove it with − and add it again.")
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.permissionTimer?.invalidate(); self.permissionTimer = nil
                    self.start()
                }
            }
            return
        }
        installRightClickTap()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication { exposeAccessibility(of: app) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        report("Everywhere mode is on. Right-click an underlined word in any app for suggestions.")
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        reset()
        report("Everywhere mode is paused.")
    }

    // MARK: Watching the focused field

    /// Electron apps (Slack, Discord, VS Code…) only build their accessibility tree when asked; Grammarly does the same.
    @objc private func appActivated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { exposeAccessibility(of: app) }
    }

    private func exposeAccessibility(of app: NSRunningApplication) {
        guard app.processIdentifier != getpid() else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func poll() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
              let focused = focusedTextElement(), let value = stringValue(of: focused),
              !value.isEmpty, (value as NSString).length <= WritingEngine.maxLength else { reset(); return }

        if element == nil || !CFEqual(element, focused) || value != text {
            element = focused
            text = value
            suggestions = WritingEngine.analyze(value).suggestions.filter { !ignored.contains($0.ignoreKey) }
            scheduleProofread(of: value)
        }
        layoutMarks()
    }

    private func focusedTextElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        // Never read password fields.
        if attribute(kAXSubroleAttribute, of: element) as? String == kAXSecureTextFieldSubrole as String { return nil }
        // Only editable text: it must report a selection range (static labels and web page text do not).
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success else { return nil }
        return element
    }

    /// Debounced on-device model pass; merges its findings behind the instant spelling/style results.
    private func scheduleProofread(of value: String) {
        proofreadTask?.cancel()
        proofreadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            let found = await AIWriter.proofread(value)
            guard let self, !Task.isCancelled, self.text == value else { return }
            self.suggestions = WritingEngine.merge(self.suggestions, found.filter { !self.ignored.contains($0.ignoreKey) })
            self.layoutMarks()
        }
    }

    private func layoutMarks() {
        guard let element else { return }
        let frame = elementFrame(element)
        marks = suggestions.compactMap { suggestion in
            guard let rect = bounds(of: suggestion.range, in: element), rect.width > 0, rect.height > 0, rect.height < 120,
                  frame.map({ $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: rect.midX, y: rect.midY)) }) ?? true else { return nil }
            return Mark(suggestion: suggestion, rect: rect)
        }
        overlay.show(marks.map { (rect: toCocoa($0.rect), color: $0.suggestion.kind.color) })
        statusItem.button?.title = suggestions.isEmpty ? "✦" : "✦ \(suggestions.count)"
        if let frame { fieldButton.show(at: toCocoa(frame), issues: suggestions.count) } else { fieldButton.orderOut(nil) }
    }

    private func reset() {
        proofreadTask?.cancel()
        element = nil; text = ""; suggestions = []; marks = []
        overlay.orderOut(nil)
        fieldButton.orderOut(nil)
        statusItem.button?.title = "✦"
    }

    // MARK: Right-click

    private func installRightClickTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true); return }
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let assistant = Unmanaged<SystemWritingAssistant>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop, so this callback runs on the main thread.
            let consumed = MainActor.assumeIsolated { assistant.handleTapEvent(type: type, location: event.location) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let eventTap else {
            report("Underlines are on, but the right-click menu could not start. Use the ✦ menu-bar icon to apply suggestions.")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0), .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Returns true when the event should be swallowed (only right-clicks that land on an underline).
    private func handleTapEvent(type: CGEventType, location: CGPoint) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap, isRunning { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        case .rightMouseDown:
            guard isRunning, let hit = marks.first(where: { $0.rect.insetBy(dx: -2, dy: -4).contains(location) }) else { return false }
            swallowNextRightMouseUp = true
            DispatchQueue.main.async { [weak self] in self?.showMenu(for: hit.suggestion) }
            return true
        case .rightMouseUp:
            defer { swallowNextRightMouseUp = false }
            return swallowNextRightMouseUp
        default:
            return false
        }
    }

    private func showMenu(for suggestion: WritingSuggestion) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addItems(for: suggestion, to: menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func addItems(for suggestion: WritingSuggestion, to menu: NSMenu) {
        let header = menu.addItem(withTitle: "\(suggestion.kind.rawValue) · \(suggestion.title)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let detail = menu.addItem(withTitle: suggestion.explanation, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(.separator())
        if let replacement = suggestion.replacement {
            addItem("Replace with “\(replacement.isEmpty ? "(remove)" : replacement)”", #selector(replace(_:)), suggestion, to: menu)
            addItem("Copy suggestion", #selector(copySuggestion(_:)), suggestion, to: menu)
        }
        menu.addItem(toneMenu("Rewrite sentence", #selector(rewriteSentence(_:)), suggestion))
        menu.addItem(.separator())
        addItem("Ignore", #selector(ignore(_:)), suggestion, to: menu)
        if suggestion.isSpelling { addItem("Add “\(suggestion.original)” to dictionary", #selector(learnWord(_:)), suggestion, to: menu) }
    }

    private func addItem(_ title: String, _ action: Selector, _ suggestion: WritingSuggestion, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = suggestion.id
    }

    private func toneMenu(_ title: String, _ action: Selector, _ suggestion: WritingSuggestion?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, tone) in WritingTone.allCases.enumerated() {
            let toneItem = submenu.addItem(withTitle: tone.rawValue, action: action, keyEquivalent: "")
            toneItem.target = self; toneItem.tag = index; toneItem.representedObject = suggestion?.id
        }
        item.submenu = submenu
        return item
    }

    /// Menu items carry the suggestion id; look it up in the live list so stale menus cannot act on old text.
    private func suggestion(for sender: NSMenuItem) -> WritingSuggestion? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return suggestions.first { $0.id == id }
    }

    // MARK: Status-bar menu (fallback when underlines cannot be drawn, e.g. apps without text bounds)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let state = menu.addItem(withTitle: isRunning ? (element == nil ? "Watching for a text field…" : "\(suggestions.count) suggestion\(suggestions.count == 1 ? "" : "s") in this field") : "Everywhere mode is off", action: nil, keyEquivalent: "")
        state.isEnabled = false
        if !AIWriter.isAvailable {
            let note = menu.addItem(withTitle: "Turn on Apple Intelligence for AI grammar and rewrites", action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
        if isRunning, element != nil {
            menu.addItem(.separator())
            addFieldItems(to: menu)
        }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: isRunning ? "Pause everywhere mode" : "Enable everywhere", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        let open = menu.addItem(withTitle: "Open Nogrammerly", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        let setup = menu.addItem(withTitle: "Setup Guide…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        let quit = menu.addItem(withTitle: "Quit Nogrammerly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    /// Suggestions for the focused field plus rewrite actions; shared by the floating field button and the menu-bar icon.
    private func addFieldItems(to menu: NSMenu) {
        for suggestion in suggestions.prefix(15) {
            let item = NSMenuItem(title: "\(suggestion.original.prefix(40)) — \(suggestion.title)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            addItems(for: suggestion, to: submenu)
            item.submenu = submenu
            menu.addItem(item)
        }
        if !suggestions.isEmpty { menu.addItem(.separator()) }
        if let element, let selection = selectedRange(of: element), selection.length > 0 {
            menu.addItem(toneMenu("Rewrite selection", #selector(rewriteSelection(_:)), nil))
        }
        menu.addItem(toneMenu("Rewrite entire text", #selector(rewriteAll(_:)), nil))
    }

    private func showFieldMenu() {
        guard element != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = menu.addItem(withTitle: suggestions.isEmpty ? "No issues found" : "\(suggestions.count) suggestion\(suggestions.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(.separator())
        addFieldItems(to: menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func toggle() { isRunning ? stop() : start() }
    @objc private func openApp() { onOpenApp?() }
    @objc private func openSetup() { onOpenSetup?() }

    // MARK: Actions

    @objc private func replace(_ sender: NSMenuItem) {
        guard let element, let suggestion = suggestion(for: sender), let replacement = suggestion.replacement else { return }
        replaceText(in: element, range: suggestion.range, expected: suggestion.original, with: replacement)
    }

    @objc private func copySuggestion(_ sender: NSMenuItem) {
        guard let replacement = suggestion(for: sender)?.replacement else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(replacement, forType: .string)
    }

    @objc private func ignore(_ sender: NSMenuItem) {
        guard let suggestion = suggestion(for: sender) else { return }
        ignored.insert(suggestion.ignoreKey)
        suggestions.removeAll { $0.ignoreKey == suggestion.ignoreKey }
        layoutMarks()
    }

    @objc private func learnWord(_ sender: NSMenuItem) {
        guard let suggestion = suggestion(for: sender) else { return }
        NSSpellChecker.shared.learnWord(suggestion.original)
        suggestions.removeAll { $0.isSpelling && $0.original == suggestion.original }
        layoutMarks()
    }

    @objc private func rewriteSentence(_ sender: NSMenuItem) {
        guard let element, let suggestion = suggestion(for: sender) else { return }
        let range = WritingEngine.sentenceRange(containing: suggestion.range, in: text)
        rewrite(range: range, in: element, tone: WritingTone.allCases[sender.tag])
    }

    @objc private func rewriteSelection(_ sender: NSMenuItem) {
        guard let element, let selection = selectedRange(of: element), selection.length > 0, NSMaxRange(selection) <= (text as NSString).length else { return }
        rewrite(range: selection, in: element, tone: WritingTone.allCases[sender.tag])
    }

    @objc private func rewriteAll(_ sender: NSMenuItem) {
        guard let element else { return }
        rewrite(range: NSRange(location: 0, length: (text as NSString).length), in: element, tone: WritingTone.allCases[sender.tag])
    }

    private func rewrite(range: NSRange, in element: AXUIElement, tone: WritingTone) {
        let original = (text as NSString).substring(with: range)
        statusItem.button?.title = "✦ …"
        Task { [weak self] in
            let rewritten = await AIWriter.rewrite(original, tone: tone) ?? WritingEngine.rewrite(original, tone: tone)
            guard let self else { return }
            self.replaceText(in: element, range: range, expected: original, with: rewritten)
            self.layoutMarks()
        }
    }

    /// Replaces `range` only if it still contains `expected`, so a stale suggestion can never overwrite newer typing.
    /// Prefers setting the selected text (keeps the app's undo and formatting); falls back to pasting over the selection.
    private func replaceText(in element: AXUIElement, range: NSRange, expected: String, with replacement: String) {
        guard let current = stringValue(of: element), NSMaxRange(range) <= (current as NSString).length,
              (current as NSString).substring(with: range) == expected else {
            report("The text changed, so that suggestion was skipped.")
            return
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            report("This app does not allow Nogrammerly to edit its text. Use Copy suggestion instead.")
            return
        }
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) != .success {
            paste(replacement)
            return
        }
        // Some apps (notably Electron) report success without changing anything; check, then paste if needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.stringValue(of: element) == current, self.selectedRange(of: element) == range else { return }
            self.paste(replacement)
        }
    }

    /// Pastes over the current selection, restoring the user's clipboard afterwards.
    private func paste(_ string: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9 /* V */, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    // MARK: Accessibility helpers

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func stringValue(of element: AXUIElement) -> String? { attribute(kAXValueAttribute, of: element) as? String }

    private func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func bounds(of range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(kAXPositionAttribute, of: element), let sizeValue = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Accessibility uses a top-left origin on the primary display; AppKit windows use bottom-left.
    private func toCocoa(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func report(_ message: String) { onStateChange?(message) }
}

/// Grammarly-style button pinned to the bottom-right corner of the field being edited. It never takes focus,
/// so the other app keeps its cursor and selection while the menu is open.
private final class FieldButtonPanel: NSPanel {
    private let button = NSButton()
    private let onClick: () -> Void
    private static let size: CGFloat = 26

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.size / 2
        button.target = self; button.action = #selector(clicked)
        button.toolTip = "Nogrammerly: suggestions and rewrites"
        button.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        contentView = button
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `field` is in AppKit screen coordinates.
    func show(at field: NSRect, issues: Int) {
        let visible = NSScreen.screens.first(where: { $0.frame.intersects(field) })?.visibleFrame ?? field
        var origin = NSPoint(x: field.maxX - Self.size - 6, y: field.minY + 6)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.size)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - Self.size)
        setFrameOrigin(origin)
        button.layer?.backgroundColor = (issues == 0 ? NSColor.systemGreen : NSColor.systemRed).cgColor
        button.attributedTitle = NSAttributedString(string: issues == 0 ? "✦" : "\(min(issues, 99))", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: issues == 0 ? 13 : 12, weight: .bold)
        ])
        orderFrontRegardless()
    }

    @objc private func clicked() { onClick() }
}

/// Transparent, click-through window that draws coloured underlines over another app's text.
private final class UnderlineOverlay: NSPanel {
    private let canvas = UnderlineView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = canvas
    }

    func show(_ marks: [(rect: NSRect, color: NSColor)]) {
        guard let first = marks.first else { orderOut(nil); return }
        let area = marks.dropFirst().reduce(first.rect) { $0.union($1.rect) }.insetBy(dx: -4, dy: -4)
        setFrame(area, display: false)
        canvas.marks = marks.map { (NSRect(x: $0.rect.minX - area.minX, y: $0.rect.minY - area.minY, width: $0.rect.width, height: $0.rect.height), $0.color) }
        canvas.needsDisplay = true
        orderFrontRegardless()
    }
}

private final class UnderlineView: NSView {
    var marks: [(rect: NSRect, color: NSColor)] = []

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            mark.color.withAlphaComponent(0.12).setFill()
            mark.rect.fill()
            let underline = NSBezierPath()
            underline.move(to: NSPoint(x: mark.rect.minX, y: mark.rect.minY + 1))
            underline.line(to: NSPoint(x: mark.rect.maxX, y: mark.rect.minY + 1))
            underline.lineWidth = 2
            mark.color.setStroke()
            underline.stroke()
        }
    }
}
