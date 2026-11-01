import AppKit
import DiffCore
import SwiftUI

/// "Ask Claude" when idle; spinner + timer + Stop while a review runs.
struct AskClaudeButton: View {
    let model: CompareModel
    @State private var isOpen = false
    @State private var draft: PromptDraft?

    var body: some View {
        Group { content }
            .sheet(item: $draft) { draft in
                PromptPreviewSheet(model: model, draft: draft) { self.draft = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        if case .running(let since) = model.reviewStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                ElapsedTime(since: since, prefix: "Reviewing ")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    model.cancelReview()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.red, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop the Claude review")
            }
        } else {
            Button {
                isOpen.toggle()
            } label: {
                // Drawn by hand: toolbars ignore .borderedProminent and render buttons greyed.
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text("Ask Claude")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.accentColor.opacity(model.files.isEmpty ? 0.4 : 1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Ask Claude to point out the lines that deserve attention")
            .disabled(model.files.isEmpty)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                AskClaudePanel(model: model) {
                    isOpen = false
                } onPreview: { command, focus in
                    isOpen = false
                    // Open the sheet once the popover has gone.
                    let prompt = model.reviewPrompt(focus: focus)
                    DispatchQueue.main.async {
                        draft = PromptDraft(command: command, focus: focus, prompt: prompt)
                    }
                }
            }
        }
    }
}

/// "1:05"-style elapsed time that ticks every second.
struct ElapsedTime: View {
    let since: Date
    var prefix = ""

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text("\(prefix)\(seconds / 60):\(String(format: "%02d", seconds % 60))")
        }
    }
}

private struct AskClaudePanel: View {
    let model: CompareModel
    let close: () -> Void
    let onPreview: (_ command: String, _ focus: String) -> Void
    @AppStorage("claudeCommand") private var command = "claude"
    @AppStorage("claudeFocus") private var focus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Ask Claude to review this diff", systemImage: "sparkles").font(.headline)
                Text("Claude reads the diff (read-only) and marks the lines worth your attention.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    TextField("claude", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if !model.recentClaudeCommands.isEmpty {
                        Menu {
                            ForEach(model.recentClaudeCommands, id: \.self) { recent in
                                Button(recent) { command = recent }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Recently used commands")
                    }
                }
                Text("The claude command, or a shell alias for it from your shell config.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Focus (optional)").font(.callout.weight(.medium))
                // Multi-line editor: Return adds a line; ⌘↩ (or the Review button) starts the review.
                PlaceholderTextEditor(text: $focus, placeholder: "e.g. error handling, concurrency, API changes…")
            }

            HStack {
                if model.isReviewing {
                    Button("Cancel Review", role: .destructive) { model.cancelReview() }
                } else {
                    Button("Preview Prompt…") { onPreview(command, focus) }
                        .disabled(model.files.isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("See, and edit, the full prompt before sending it to Claude")
                }
                Spacer()
                Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
                Button(model.storedReview == nil ? "Review" : "Review Again") {
                    model.startReview(command: command, focus: focus)
                    close()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    model.isReviewing || model.files.isEmpty
                        || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

// MARK: - Prompt preview

struct PromptDraft: Identifiable {
    let id = UUID()
    let command: String
    let focus: String
    let prompt: String
}

/// Shows the full prompt that will be sent to Claude and lets the user edit it first.
private struct PromptPreviewSheet: View {
    let model: CompareModel
    let draft: PromptDraft
    let close: () -> Void
    @State private var text: String

    init(model: CompareModel, draft: PromptDraft, close: @escaping () -> Void) {
        self.model = model
        self.draft = draft
        self.close = close
        _text = State(initialValue: draft.prompt)
    }

    private var isEdited: Bool { text != draft.prompt }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Review prompt", systemImage: "text.bubble").font(.headline)
                Text(
                    "This is sent to `\(draft.command)` on stdin. Edit it freely; the reply format "
                        + "(summary + line comments) is enforced separately, so keep asking for those fields."
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .inputBox()

            HStack(spacing: 10) {
                Text(
                    "\(text.count.formatted()) characters · ~\((text.utf8.count / 4).formatted()) tokens"
                        + (isEdited ? " · edited" : "")
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Reset") { text = draft.prompt }
                    .disabled(!isEdited)
                    .help("Go back to the generated prompt")
                Button("Copy") { Pasteboard.copy(text) }
                    .help("Copy the prompt to the clipboard")
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
                Button("Send to Claude") {
                    model.startReview(
                        command: draft.command, focus: draft.focus,
                        customPrompt: isEdited ? text : nil)
                    close()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isEmpty || model.isReviewing)
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 900, minHeight: 420, idealHeight: 680)
    }
}
