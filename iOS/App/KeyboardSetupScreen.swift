import SwiftUI
import UIKit
import NogrammerlyCore

struct KeyboardSetupScreen: View {
    @State private var tryText = ""

    var body: some View {
        List {
            Section {
                Label("Check your writing in Messages, Mail, Slack, Notes and any other app, right from the keyboard.", systemImage: "keyboard.badge.ellipsis")
            }
            Section("Turn on the keyboard") {
                step(1, "Tap **Open Settings** below.")
                step(2, "Tap **Keyboards**, then turn on **Nogrammerly**.")
                step(3, "In any app, hold the 🌐 key and choose **Nogrammerly**.")
                Button("Open Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section("How it works") {
                Label("Suggestions appear above the keys. Tap one to fix it. Press and hold one to ignore it.", systemImage: "text.badge.checkmark")
                Label("Tap ✦ to rewrite what you've typed in a different tone.", systemImage: "sparkles")
                Label(AIWriter.isAvailable ? "Grammar, clarity and tone checks use Apple's on-device model." : "Turn on Apple Intelligence in Settings for grammar, tone and rewrite checks. Spelling and style checks work without it.",
                      systemImage: AIWriter.isAvailable ? "apple.intelligence" : "exclamationmark.triangle")
            }
            Section {
                Label("Nogrammerly does not ask for Full Access, so iOS blocks the keyboard from the network. What you type stays on this device.", systemImage: "lock.shield")
            } header: {
                Text("Privacy")
            }
            Section("Try it") {
                TextField("Type here with the Nogrammerly keyboard", text: $tryText, axis: .vertical)
                    .accessibilityIdentifier("tryField")
                    .lineLimit(3...6)
            }
        }
        .navigationTitle("Keyboard")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.headline).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(.indigo, in: .circle)
            Text(text)
        }
    }
}
