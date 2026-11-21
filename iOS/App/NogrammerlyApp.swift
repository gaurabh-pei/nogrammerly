import SwiftUI
import NogrammerlyCore

@main
struct NogrammerlyApp: App {
    /// One document for the whole app, so iPad windows show the same text instead of overwriting each other.
    @State private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Write", systemImage: "square.and.pencil") {
                    NavigationStack { EditorScreen(model: model) }
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
