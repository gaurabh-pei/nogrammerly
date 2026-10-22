import AppKit

/// Grammarly-style rewrite card shown next to the text being rewritten: ask for a writing style, show the rewrite,
/// then Accept / Copy / Reject / Retry (Retry asks for a style again). It never takes focus, so the other app keeps
/// its cursor and selection; clicking elsewhere or pressing Escape closes it.
@MainActor
final class RewritePanel: NSPanel {
    private static let width: CGFloat = 400
    private var original = ""
    private var anchor = NSRect.zero
    private var result = ""
    private var onAccept: ((String) -> Void)?
    private var rewriteTask: Task<Void, Never>?
    private var monitors: [Any] = []

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .popUpMenu; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `anchor` is the text's on-screen rect in AppKit coordinates. With a `tone` the style question is skipped.
    func present(original: String, near anchor: NSRect, tone: WritingTone? = nil, onAccept: @escaping (String) -> Void) {
        close()
        self.original = original; self.anchor = anchor; self.onAccept = onAccept
        if let tone { generate(tone) } else { askForStyle() }
        orderFrontRegardless()
        // Global monitors only see events aimed at other apps, so clicks on this card's own buttons are unaffected.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in MainActor.assumeIsolated { self?.close() } },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in MainActor.assumeIsolated { if event.keyCode == 53 { self?.close() } } }
        ].compactMap { $0 }
    }

    override func close() {
        rewriteTask?.cancel(); rewriteTask = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        onAccept = nil
        orderOut(nil)
    }

    // MARK: Steps

    private func askForStyle() {
        let styles = NSStackView(views: WritingTone.allCases.enumerated().map { index, tone in
            let button = NSButton(title: tone.rawValue, target: self, action: #selector(styleChosen(_:)))
            button.tag = index; button.bezelColor = .systemIndigo
            return button
        })
        styles.distribution = .fillEqually
        show([title("Rewrite in which style?"), quote(original, lines: 3), styles, buttons([("Cancel", #selector(reject))])])
    }

    private func generate(_ tone: WritingTone) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, title("Rewriting as \(tone.rawValue)…")])
        show([row, quote(original, lines: 3), buttons([("Cancel", #selector(reject))])])
        rewriteTask = Task { [weak self, original] in
            let rewritten = await AIWriter.rewrite(original, tone: tone) ?? WritingEngine.rewrite(original, tone: tone)
            guard let self, !Task.isCancelled else { return }
            self.showResult(rewritten, tone: tone)
        }
    }

    private func showResult(_ rewritten: String, tone: WritingTone) {
        result = rewritten
        show([title("\(tone.rawValue) rewrite"), scrollingText(rewritten),
              buttons([("Accept", #selector(accept)), ("Copy", #selector(copyResult)), ("Reject", #selector(reject)), ("Retry", #selector(retry))])])
    }

    // MARK: Actions

    @objc private func styleChosen(_ sender: NSButton) { generate(WritingTone.allCases[sender.tag]) }
    @objc private func retry() { askForStyle() }
    @objc private func reject() { close() }

    @objc private func accept() {
        let onAccept = onAccept, result = result
        close()
        onAccept?(result)
    }

    @objc private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        close()
    }

    // MARK: Layout

    private func show(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        views.forEach { $0.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 28).isActive = true }
        let background = NSVisualEffectView()
        background.material = .popover; background.state = .active; background.wantsLayer = true
        background.layer?.cornerRadius = 10; background.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: background.topAnchor), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
                                     stack.widthAnchor.constraint(equalToConstant: Self.width)])
        contentView = background
        background.layoutSubtreeIfNeeded()
        place(size: NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    /// Below the text when there is room, otherwise above it; always on the text's screen.
    private func place(size: NSSize) {
        let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func title(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func quote(_ string: String, lines: Int) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = lines; label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.width - 28
        return label
    }

    private func scrollingText(_ string: String) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let textView = scroll.documentView as! NSTextView
        textView.string = string; textView.isEditable = false; textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13); textView.textContainerInset = .zero
        textView.textContainer?.containerSize = NSSize(width: Self.width - 28, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let height = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 60
        scroll.heightAnchor.constraint(equalToConstant: min(max(height + 4, 20), 240)).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        return scroll
    }

    private func buttons(_ specs: [(String, Selector)]) -> NSStackView {
        let row = NSStackView(views: specs.map { title, action in NSButton(title: title, target: self, action: action) })
        if specs.count > 1 { (row.views.first as? NSButton)?.bezelColor = .systemIndigo }
        return row
    }
}
