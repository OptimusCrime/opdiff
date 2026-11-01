import AppKit
import DiffCore
import SwiftUI

/// ⌘F bar above the diff: finds text in every shown line.
struct FindBar: View {
    @Bindable var model: CompareModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in diff", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
                .focused($focused)
                // Return: next match; ⇧Return: previous.
                .onSubmit { model.findNext(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { model.closeFind() }
            Text(status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            HStack(spacing: 2) {
                Button { model.findNext(forward: false) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                Button { model.findNext(forward: true) } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
            }
            .disabled(model.searchMatches.isEmpty)
            Spacer()
            Button("Done") { model.closeFind() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onChange(of: model.findFocusToken) { focused = true }
    }

    private var status: String {
        let count = model.searchMatches.count
        if model.searchQuery.isEmpty { return "" }
        if count == 0 { return "No matches" }
        let total = count >= CompareModel.searchLimit ? "\(count)+" : "\(count)"
        return model.currentMatchIndex.map { "\($0 + 1) of \(total)" } ?? "\(total) matches"
    }
}

/// "Ask Claude about these lines": shows the lines and takes a question.
struct QuestionSheet: View {
    let model: CompareModel
    let draft: QuestionDraft
    @AppStorage("claudeCommand") private var command = "claude"
    @State private var question = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ask Claude about \(draft.reference)", systemImage: "questionmark.bubble")
                .font(.headline)
                .lineLimit(1).truncationMode(.middle)

            ScrollView {
                Text(draft.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            TextEditor(text: $question)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4).padding(.vertical, 6)
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if question.isEmpty {
                        Text("e.g. Can this run twice at the same time? Why is the old check removed?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Text("Command").foregroundStyle(.secondary)
                TextField("claude", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 160)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
                Button("Ask Claude") {
                    model.askQuestion(draft, question: question, command: command)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canAsk)
            }
            Text("The answer appears under these lines in the diff and in the review panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 580)
        .onAppear { focused = true }
    }
}

/// Reports the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
