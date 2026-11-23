import AppKit
import ApplicationServices
import NogrammerlyCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let assistant: SystemWritingAssistant
    private let preferences = AppPreferences()
    private let hideFromDock = NSButton(checkboxWithTitle: "Hide Nogrammerly from the Dock", target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let everywhereMode = NSButton(checkboxWithTitle: "Enable Everywhere mode", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let appleIntelligenceStatus = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")

    init(assistant: SystemWritingAssistant) {
        self.assistant = assistant
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nogrammerly Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 20, weight: .bold)

        hideFromDock.target = self
        hideFromDock.action = #selector(changeHideFromDock)
        launchAtLogin.target = self
        launchAtLogin.action = #selector(toggleLaunchAtLogin)
        everywhereMode.target = self
        everywhereMode.action = #selector(toggleEverywhereMode)

        let dockDetail = detail("Keep Nogrammerly available from the ✦ menu-bar icon without showing it in the Dock or Command-Tab switcher. Changing this requires a restart.")
        let everywhereDetail = detail("Checks writing in TextEdit, Notes, Slack and other supported apps through Accessibility.")

        let accessibilityButton = button("Open Accessibility Settings", action: #selector(openAccessibilitySettings))
        let appleIntelligenceButton = button("Open Apple Intelligence Settings", action: #selector(openAppleIntelligenceSettings))
        accessibilityStatus.font = .systemFont(ofSize: 12)
        appleIntelligenceStatus.font = .systemFont(ofSize: 12)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 420

        let accessibilityRow = NSStackView(views: [accessibilityStatus, accessibilityButton])
        accessibilityRow.orientation = .vertical
        accessibilityRow.alignment = .leading
        accessibilityRow.spacing = 6
        let appleRow = NSStackView(views: [appleIntelligenceStatus, appleIntelligenceButton])
        appleRow.orientation = .vertical
        appleRow.alignment = .leading
        appleRow.spacing = 6

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title,
            launchAtLogin,
            hideFromDock, dockDetail,
            everywhereMode, everywhereDetail,
            separator(), accessibilityRow,
            appleRow,
            message,
            NSView(), done
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dockDetail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            everywhereDetail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64)
        ])
        return root
    }

    private func detail(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 420
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func refresh() {
        hideFromDock.state = preferences.hideFromDock ? .on : .off
        launchAtLogin.state = LaunchAtLogin.isEnabled ? .on : .off
        everywhereMode.state = assistant.isRunning || assistant.isWaitingForAccessibility ? .on : .off
        let hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility { accessibilityStatus.stringValue = "Accessibility: allowed" }
        else if assistant.isWaitingForAccessibility { accessibilityStatus.stringValue = "Accessibility: waiting for permission…" }
        else { accessibilityStatus.stringValue = "Accessibility: permission required" }
        accessibilityStatus.textColor = hasAccessibility ? .systemGreen : .systemOrange
        appleIntelligenceStatus.stringValue = AIWriter.isAvailable ? "Apple Intelligence: available" : "Apple Intelligence: unavailable"
        appleIntelligenceStatus.textColor = AIWriter.isAvailable ? .systemGreen : .secondaryLabelColor
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        if let warning = LaunchAtLogin.toggle() {
            message.stringValue = warning
        } else {
            message.stringValue = ""
        }
        refresh()
    }

    @objc private func toggleEverywhereMode(_ sender: NSButton) {
        assistant.toggleEverywhereMode()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openAppleIntelligenceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }

    @objc private func changeHideFromDock(_ sender: NSButton) {
        preferences.hideFromDock = sender.state == .on
        let bundleURL = Bundle.main.bundleURL
        // A direct SwiftPM launch has no app bundle for Launch Services to reopen.
        guard bundleURL.pathExtension.lowercased() == "app" else { return }

        let alert = NSAlert()
        alert.messageText = "Restart Nogrammerly?"
        alert.informativeText = "The Dock setting takes effect after Nogrammerly restarts. Restarting discards the current text in the editor."
        alert.addButton(withTitle: "Quit and Reopen")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
            bundleURL.path
        ]
        relaunch.standardOutput = FileHandle.nullDevice
        relaunch.standardError = FileHandle.nullDevice

        do {
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.runModal()
        }
    }
}
