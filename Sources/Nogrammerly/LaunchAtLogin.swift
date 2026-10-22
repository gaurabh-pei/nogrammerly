import ServiceManagement

/// Starts Nogrammerly when the user logs in, so everywhere mode survives a restart.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Flips the setting; returns a message for the user when it needs their attention or fails.
    static func toggle() -> String? {
        do {
            if isEnabled { try SMAppService.mainApp.unregister(); return nil }
            try SMAppService.mainApp.register()
        } catch {
            return "Could not change Launch at Login: \(error.localizedDescription)"
        }
        guard SMAppService.mainApp.status == .requiresApproval else { return nil }
        SMAppService.openSystemSettingsLoginItems()
        return "Turn on Nogrammerly in System Settings › General › Login Items to finish."
    }
}
