import AppKit
import Testing
@testable import Nogrammerly

@MainActor
@Suite struct AppPreferencesTests {
    @Test func dockVisibilityDefaultsToVisible() throws {
        let suiteName = "Nogrammerly.AppPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.hideFromDock)
        #expect(preferences.activationPolicy == .regular)
    }

    @Test(arguments: [true, false])
    func savedDockVisibilityDeterminesActivationPolicy(hideFromDock: Bool) throws {
        let suiteName = "Nogrammerly.AppPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.hideFromDock = !hideFromDock
        preferences.hideFromDock = hideFromDock

        let reopened = AppPreferences(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reopened.hideFromDock == hideFromDock)
        #expect(reopened.activationPolicy == (hideFromDock ? .accessory : .regular))
    }
}
