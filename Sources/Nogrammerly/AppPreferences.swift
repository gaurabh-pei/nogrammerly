import Foundation
import AppKit

@MainActor
struct AppPreferences {
    private static let hideFromDockKey = "hideFromDock"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hideFromDock: Bool {
        get { defaults.bool(forKey: Self.hideFromDockKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hideFromDockKey) }
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        hideFromDock ? .accessory : .regular
    }
}
