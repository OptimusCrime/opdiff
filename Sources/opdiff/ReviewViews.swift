import DiffCore
import SwiftUI

extension AnnotationKind {
    var color: Color {
        switch self {
        case .important: .orange
        case .attention: .yellow
        case .info: .blue
        }
    }

    var icon: String {
        switch self {
        case .important: "exclamationmark.triangle.fill"
        case .attention: "eye.fill"
        case .info: "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .important: "Important"
        case .attention: "Attention"
        case .info: "Info"
        }
    }
}

// MARK: - Toolbar

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
                Button { model.cancelReview() } label: {
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
            Button { isOpen.toggle() } label: {
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
                AskClaudePanel(model: model) { isOpen = false } onPreview: { command, focus in
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
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Recently used commands")
                    }
                }
                Text("A command or shell alias from your shell config, e.g. claude, pclaude, tclaude.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Focus (optional)").font(.callout.weight(.medium))
                // Multi-line editor: Return adds a line; ⌘↩ (or the Review button) starts the review.
                TextEditor(text: $focus)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .frame(height: 96)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    .overlay(alignment: .topLeading) {
                        if focus.isEmpty {
                            Text("e.g. error handling, concurrency, API changes…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
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
                .disabled(model.isReviewing || model.files.isEmpty
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
                Text("This is sent to `\(draft.command)` on stdin. Edit it freely; the reply format "
                     + "(summary + line comments) is enforced separately, so keep asking for those fields.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            HStack(spacing: 10) {
                Text("\(text.count.formatted()) characters · ~\((text.utf8.count / 4).formatted()) tokens"
                     + (isEdited ? " · edited" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Reset") { text = draft.prompt }
                    .disabled(!isEdited)
                    .help("Go back to the generated prompt")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help("Copy the prompt to the clipboard")
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
                Button("Send to Claude") {
                    model.startReview(command: draft.command, focus: draft.focus,
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

// MARK: - Inline status/summary (top of the diff)

struct ReviewPanel: View {
    let model: CompareModel
    let onOpenReview: () -> Void

    var body: some View {
        switch model.reviewStatus {
        case .running(let since):
            ReviewBox(tint: .accentColor) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Claude is reviewing the diff…")
                    ElapsedTime(since: since).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", role: .destructive) { model.cancelReview() }
                }
            }
        case .failed(let message):
            ReviewBox(tint: .red) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude review failed").font(.headline)
                        Text(message).font(.callout.monospaced()).lineLimit(4).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Dismiss") { model.dismissReviewError() }
                }
            }
        case .idle:
            if let stored = model.storedReview {
                ReviewBox(tint: .accentColor) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Label("Claude review", systemImage: "sparkles").font(.headline)
                            KindCounts(annotations: stored.review.annotations)
                            Spacer()
                            Button("Open Review Panel", action: onOpenReview).buttonStyle(.link)
                        }
                        if model.reviewIsOutdated {
                            Label("The diff has changed since this review.", systemImage: "clock.badge.exclamationmark")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        Text(stored.review.summary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Side panel with the whole review

struct ReviewInspector: View {
    let model: CompareModel
    let onClose: () -> Void
    let onJump: (Annotation) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Claude Review", systemImage: "sparkles").font(.title3.bold())
                    Spacer()
                    if model.storedReview != nil {
                        clearButton
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close the review panel")
                }
                status
                if let stored = model.storedReview {
                    review(stored)
                } else if !model.isReviewing {
                    ContentUnavailableView {
                        Label("No review yet", systemImage: "sparkles")
                    } description: {
                        Text("Click **Ask Claude** in the toolbar to have Claude point out the lines in this diff that deserve attention.")
                    }
                    .padding(.top, 24)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.reviewStatus {
        case .running(let since):
            ReviewBox(tint: .accentColor) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reviewing…").font(.headline)
                        Spacer()
                        ElapsedTime(since: since).font(.title3.monospacedDigit())
                    }
                    if let target = model.reviewTarget {
                        Text(target).font(.callout).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { model.cancelReview() } label: {
                        Label("Stop Review", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        case .failed(let message):
            ReviewBox(tint: .red) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Review failed", systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(.red)
                    Text(message).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Dismiss") { model.dismissReviewError() }
                }
            }
        case .idle:
            EmptyView()
        }
    }

    private func review(_ stored: CompareModel.StoredReview) -> some View {
        let annotations = stored.review.annotations
        let byFile = Dictionary(grouping: annotations, by: \.file)
        let files = byFile.keys.sorted()
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                KindCounts(annotations: annotations)
                Text("\(stored.command) · \(stored.createdAt.formatted(date: .abbreviated, time: .shortened))"
                     + (stored.costUSD.map { String(format: " · $%.2f", $0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if !stored.focus.isEmpty {
                    Text("Focus: \(stored.focus)").font(.caption).foregroundStyle(.secondary)
                }
                if model.reviewIsOutdated {
                    Label("The diff has changed since this review — comments may point at the wrong lines. Ask Claude again to refresh it.",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Summary").font(.headline)
                Text(stored.review.summary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !annotations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Comments (\(annotations.count))").font(.headline)
                    ForEach(files, id: \.self) { file in
                        let fileAnnotations = byFile[file]!.sorted { $0.startLine < $1.startLine }
                        let inDiff = model.fileID(for: fileAnnotations[0]) != nil
                        VStack(alignment: .leading, spacing: 6) {
                            if !inDiff {
                                Text("This file isn't part of the current diff.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { onJump(fileAnnotations[0]) } label: {
                                Label(file, systemImage: "doc.text")
                                    .font(.callout.monospaced().weight(.semibold))
                                    .lineLimit(1).truncationMode(.head)
                            }
                            .buttonStyle(.link)
                            .disabled(!inDiff)
                            .help(inDiff ? "Jump to \(file)" : "This file isn't part of the current diff")
                            // Index-based identity: robust even if two comments are identical.
                            ForEach(Array(fileAnnotations.enumerated()), id: \.offset) { _, annotation in
                                Button { onJump(annotation) } label: { commentRow(annotation) }
                                    .buttonStyle(.plain)
                                    .disabled(!inDiff)
                                    .opacity(inDiff ? 1 : 0.5)
                                    .help(inDiff ? "Show this comment in the diff" : "This file isn't part of the current diff")
                            }
                        }
                    }
                }
            }

            clearButton
        }
    }

    private var clearButton: some View {
        Button("Clear Review", role: .destructive) { model.clearReview() }
            .buttonStyle(.link)
            .help("Remove this review and its comments from the diff")
    }

    private func commentRow(_ annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: annotation.kind.icon).foregroundStyle(annotation.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(annotation.kind.label) · \(annotation.side == .old ? "old " : "")\(annotation.lineLabel)")
                    .font(.caption.weight(.semibold)).foregroundStyle(annotation.kind.color)
                Text(annotation.comment)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(annotation.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

private struct KindCounts: View {
    let annotations: [Annotation]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AnnotationKind.allCases, id: \.self) { kind in
                let count = annotations.filter { $0.kind == kind }.count
                if count > 0 {
                    Label("\(count) \(kind.label.lowercased())", systemImage: kind.icon)
                        .font(.caption)
                        .foregroundStyle(kind.color)
                }
            }
            if annotations.isEmpty {
                Text("No comments").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReviewBox<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
    }
}

// MARK: - Inline comments

/// A request from the review panel to scroll to a comment. The token makes repeated
/// clicks on the same comment count as new requests.
struct JumpRequest: Equatable {
    let annotation: Annotation
    let token = UUID()
}

struct AnnotationCard: View {
    let annotation: Annotation
    var note: String?
    var isFlashing = false

    var body: some View {
        let kind = annotation.kind
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.icon).foregroundStyle(kind.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.label).font(.caption.weight(.bold)).foregroundStyle(kind.color)
                    Text("Claude · \(annotation.side == .old ? "old " : "")\(annotation.lineLabel)"
                         + (note.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(annotation.comment)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
                .fill(kind.color)
                .frame(width: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(kind.color, lineWidth: 2)
                .opacity(isFlashing ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: isFlashing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small "✦ 3" badge for files with comments.
struct AnnotationBadge: View {
    let count: Int
    let kind: AnnotationKind

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles")
            Text("\(count)")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(kind.color)
        .help("\(count) comment\(count == 1 ? "" : "s") from Claude")
    }
}

/// Coloured bar on the leading edge of a commented line.
struct AnnotationMarker: ViewModifier {
    let kind: AnnotationKind?

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if let kind {
                Rectangle().fill(kind.color).frame(width: 4).padding(.leading, 1)
            }
        }
    }
}

/// Draggable divider for the review pane.
struct PaneDivider: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(640, max(280, start - value.translation.width))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
