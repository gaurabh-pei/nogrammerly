import AppKit
import ApplicationServices

/// First-run and on-demand setup guide. Each step shows its live status, so the user can see exactly what is left to do.
@MainActor
final class SetupWindowController: NSWindowController {
    private struct Step {
        let title: String
        let detail: String
        let optional: Bool
        let isDone: () -> Bool
        let actionTitle: String?
        let action: (() -> Void)?
        var secondaryTitle: String? = nil
        var secondaryAction: (() -> Void)? = nil
    }

    private let assistant: SystemWritingAssistant
    private var steps: [Step] = []
    private var statusIcons: [NSTextField] = []
    private var actionButtons: [NSButton] = []
    private var secondaryButtons: [NSButton] = []
    private let summary = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?

    var isSetupComplete: Bool { steps.filter { !$0.optional }.allSatisfy { $0.isDone() } }

    init(assistant: SystemWritingAssistant) {
        self.assistant = assistant
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Nogrammerly Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        steps = makeSteps()
        window.contentView = makeContent()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose() { refreshTimer?.invalidate(); refreshTimer = nil }

    private func makeSteps() -> [Step] {
        let bundlePath = Bundle.main.bundlePath
        return [
            Step(title: "Install in Applications",
                 detail: bundlePath.hasPrefix("/Volumes/")
                    ? "You are running Nogrammerly from the installer disk. Drag it into Applications, eject the disk and open it from there."
                    : "Nogrammerly is installed at \(bundlePath).",
                 optional: false,
                 isDone: { !bundlePath.hasPrefix("/Volumes/") },
                 actionTitle: nil, action: nil),
            Step(title: "Allow Accessibility access",
                 detail: "Lets Nogrammerly read and correct the text field you are typing in. System Settings › Privacy & Security › Accessibility › turn on Nogrammerly.\nIf Nogrammerly is already switched on but this step stays amber, macOS is holding an approval for an older build: click Reset & Ask Again, then switch it on once more.",
                 optional: false,
                 isDone: { AXIsProcessTrusted() },
                 actionTitle: "Open Accessibility Settings",
                 action: { [weak self] in self?.requestAccessibility() },
                 secondaryTitle: "Reset & Ask Again",
                 secondaryAction: { [weak self] in self?.resetAccessibility() }),
            Step(title: "Turn on everywhere mode",
                 detail: "Checks your writing in Slack, Notes, Mail, Zoom, Sublime Text and most other apps. Starts automatically once access is allowed.",
                 optional: false,
                 isDone: { [weak self] in self?.assistant.isRunning ?? false },
                 actionTitle: "Turn On",
                 action: { [weak self] in self?.assistant.start() }),
            Step(title: "Turn on Apple Intelligence (optional)",
                 detail: "Adds AI grammar, clarity and tone checks plus sentence rewrites, all on this Mac. Without it you still get spelling, grammar and style checks.",
                 optional: true,
                 isDone: { AIWriter.isAvailable },
                 actionTitle: "Open Apple Intelligence Settings",
                 action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!) }),
            Step(title: "Try it",
                 detail: "Open TextEdit or Notes and type:  I recieve alot of messages.\nThe mistakes get underlined. Right-click an underline to Replace, Copy, Rewrite or Ignore, or click the round button in the field's corner.",
                 optional: true,
                 isDone: { false },
                 actionTitle: "Open TextEdit",
                 action: { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/TextEdit.app")) })
        ]
    }

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let title = NSTextField(labelWithString: "Set up Nogrammerly")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, summary]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 4
        let header = NSStackView(views: [icon, heading]); header.spacing = 16; header.alignment = .centerY

        var rows: [NSView] = [header, separator()]
        for (index, step) in steps.enumerated() {
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 20, weight: .semibold)
            status.alignment = .center
            status.widthAnchor.constraint(equalToConstant: 28).isActive = true
            statusIcons.append(status)

            let name = NSTextField(labelWithString: "\(index + 1). \(step.title)")
            name.font = .systemFont(ofSize: 14, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: step.detail)
            detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 520
            var texts: [NSView] = [name, detail]
            let button = NSButton(title: step.actionTitle ?? "", target: self, action: #selector(runStep(_:)))
            button.tag = index; button.bezelStyle = .rounded
            let secondary = NSButton(title: step.secondaryTitle ?? "", target: self, action: #selector(runSecondary(_:)))
            secondary.tag = index; secondary.bezelStyle = .rounded
            if step.actionTitle != nil {
                let buttons = NSStackView(views: step.secondaryTitle == nil ? [button] : [button, secondary])
                buttons.spacing = 8
                texts.append(buttons)
            }
            actionButtons.append(button)
            secondaryButtons.append(secondary)
            let textStack = NSStackView(views: texts); textStack.orientation = .vertical; textStack.alignment = .leading; textStack.spacing = 5
            let row = NSStackView(views: [status, textStack]); row.alignment = .top; row.spacing = 10
            rows.append(row)
        }

        rows.append(separator())
        let usageTitle = NSTextField(labelWithString: "How it works")
        usageTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        rows.append(usageTitle)
        let usage = NSTextField(wrappingLabelWithString: """
            • Underline colours: red = correctness, blue = clarity, purple = delivery, orange = style.
            • A round button appears in the bottom-right corner of the field you're typing in: green ✦ means no issues, red shows the number of suggestions. Click it to see them all, or to rewrite your selection or the whole text in a Professional, Friendly, Confident or Concise tone.
            • Right-click an underline for Replace, Copy suggestion, Rewrite sentence (Professional, Friendly, Confident, Concise), Ignore or Add to dictionary.
            • The ✦ icon in the menu bar shows how many issues the current field has, lists them all, and can rewrite the whole text or pause everywhere mode.
            • Everything runs on this Mac. Your text is never sent anywhere.
            """)
        usage.font = .systemFont(ofSize: 12)
        usage.preferredMaxLayoutWidth = 560
        rows.append(usage)

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        rows.append(footer)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56)
        ])
        return root
    }

    private func separator() -> NSView {
        let box = NSBox(); box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 564).isActive = true
        return box
    }

    @objc private func runStep(_ sender: NSButton) { steps[sender.tag].action?() }
    @objc private func runSecondary(_ sender: NSButton) { steps[sender.tag].secondaryAction?() }

    private func requestAccessibility() {
        assistant.start()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// macOS ties the Accessibility approval to the exact signed build. When an approval exists for a different build the
    /// switch looks on but access is denied; clearing Nogrammerly's own entry lets macOS ask again for this build.
    private func resetAccessibility() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.nogrammerly.app"]
        do {
            try reset.run()
            reset.waitUntilExit()
        } catch {
            summary.stringValue = "Could not reset the permission: \(error.localizedDescription)"
            return
        }
        requestAccessibility()
    }

    private func refresh() {
        for (index, step) in steps.enumerated() {
            let done = step.isDone()
            statusIcons[index].stringValue = done ? "✓" : step.optional ? "○" : "●"
            statusIcons[index].textColor = done ? .systemGreen : step.optional ? .tertiaryLabelColor : .systemOrange
            // "Try it" stays clickable; other actions disappear once their step is done.
            actionButtons[index].isHidden = step.actionTitle == nil || (done && index != steps.count - 1)
            secondaryButtons[index].isHidden = step.secondaryTitle == nil || done
        }
        summary.stringValue = isSetupComplete
            ? "You're all set. Start typing in any app."
            : "A few steps and Nogrammerly will check your writing in every app."
    }
}
