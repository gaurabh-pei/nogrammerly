import SwiftUI
import NogrammerlyCore

@main
struct NogrammerlyApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Write", systemImage: "square.and.pencil") {
                    NavigationStack { EditorScreen() }
                }
                Tab("Keyboard", systemImage: "keyboard") {
                    NavigationStack { KeyboardSetupScreen() }
                }
            }
            .tint(.indigo)
            // A cold first model request can take a minute; load the model while the user starts typing.
            .task { AIWriter.prewarm() }
        }
    }
}
