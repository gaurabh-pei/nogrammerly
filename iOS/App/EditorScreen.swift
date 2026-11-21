import SwiftUI
import UIKit
import NogrammerlyCore

struct EditorScreen: View {
    @State private var model = EditorModel()
    @State private var showsAllSuggestions = false

    var body: some View {
        HighlightingTextView(text: $model.text, suggestions: model.suggestions)
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) { suggestionStrip }
            .navigationTitle("Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Score \(model.analysis.readability)", systemImage: "list.bullet.rectangle") { showsAllSuggestions = true }
                        .labelStyle(.titleAndIcon)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Tone", selection: $model.tone) {
                            ForEach(WritingTone.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(model.tone.rawValue, systemImage: "theatermasks")
                    }
                    Button { model.startRewrite() } label: {
                        if model.isRewriting { ProgressView() } else { Label("Rewrite", systemImage: "sparkles") }
                    }
                    .disabled(model.isRewriting)
                    Menu {
                        Button("Copy All", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.text }
                        ShareLink(item: model.text)
                        Button("New Document", systemImage: "trash", role: .destructive) { model.clear() }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $model.rewrite) { rewrite in
                RewriteSheet(rewrite: rewrite, accept: { model.accept(rewrite) }, retry: { model.rewrite = nil; model.startRewrite() })
            }
            .sheet(isPresented: $showsAllSuggestions) {
                SuggestionListSheet(model: model)
            }
            .alert("Rewrite", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: {
                Text(model.message ?? "")
            }
    }

    private var suggestionStrip: some View {
        VStack(spacing: 0) {
            Divider()
            if model.suggestions.isEmpty {
                Label(model.text.contains(where: \.isLetter) ? "Looks good. No suggestions." : "Start writing to get suggestions.", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.suggestions, id: \.id) { suggestion in
                            SuggestionCard(suggestion: suggestion, apply: { model.apply(suggestion) }, ignore: { model.ignore(suggestion) })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(.bar)
    }
}

struct SuggestionCard: View {
    let suggestion: WritingSuggestion
    let apply: () -> Void
    let ignore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(suggestion.kind.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Color(suggestion.kind.color))
                if let replacement = suggestion.replacement {
                    (Text(suggestion.original).strikethrough().foregroundStyle(.secondary) + Text("  →  ") + Text(replacement).bold())
                        .font(.subheadline).lineLimit(2)
                } else {
                    Text(suggestion.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    if suggestion.replacement != nil { Button("Accept", action: apply).buttonStyle(.borderedProminent) }
                    Button("Ignore", action: ignore).buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        // The colour bar would otherwise grow to fill all the height it is offered.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }
}

struct SuggestionListSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Writing score", value: "\(model.analysis.readability)")
                    LabeledContent("Words", value: "\(model.analysis.words)")
                    LabeledContent("Tone", value: model.analysis.tone)
                }
                Section("\(model.suggestions.count) suggestions") {
                    ForEach(model.suggestions, id: \.id) { suggestion in
                        SuggestionCard(suggestion: suggestion, apply: { model.apply(suggestion) }, ignore: { model.ignore(suggestion) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }
            .navigationTitle("Suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct RewriteSheet: View {
    let rewrite: EditorModel.Rewrite
    let accept: () -> Void
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(rewrite.tone.rawValue) rewrite").font(.headline)
                    Text(rewrite.rewritten).textSelection(.enabled)
                    Divider()
                    Text("Original").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(rewrite.original).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Rewrite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reject") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Accept", action: accept) }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = rewrite.rewritten }
                    Spacer()
                    Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// UITextView with coloured underlines under each suggestion. SwiftUI's TextEditor can't underline ranges.
struct HighlightingTextView: UIViewRepresentable {
    @Binding var text: String
    let suggestions: [WritingSuggestion]

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        // Nogrammerly does its own checking; the system's red dots would double up.
        view.spellCheckingType = .no
        view.autocorrectionType = .no
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        // Changing attributes while the user is composing (e.g. Japanese input) would cancel the composition.
        guard view.markedTextRange == nil else { return }
        let storage = view.textStorage
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: all)
        storage.removeAttribute(.underlineColor, range: all)
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: all)
        for suggestion in suggestions where NSMaxRange(suggestion.range) <= all.length {
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: suggestion.kind.color], range: suggestion.range)
        }
        storage.endEditing()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightingTextView
        init(parent: HighlightingTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
