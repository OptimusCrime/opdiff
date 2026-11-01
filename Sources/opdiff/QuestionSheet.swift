import AppKit
import DiffCore
import SwiftUI

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
            .inputBox()

            PlaceholderTextEditor(
                text: $question,
                placeholder: "e.g. Can this run twice at the same time? Why is the old check removed?",
                focus: $focused)

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
