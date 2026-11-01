import AppKit
import DiffCore
import SwiftUI

/// Side panel with the whole review: summary, comments and your questions.

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
                        Text(
                            "Click **Ask Claude** in the toolbar to have Claude point out the lines in this diff that deserve attention.\n\nTo ask about specific lines, select them and press **A** (or right-click them)."
                        )
                    }
                    .padding(.top, 24)
                }
                if !model.questions.isEmpty {
                    questions
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
                    Button(role: .destructive) {
                        model.cancelReview()
                    } label: {
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

    private var questions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your questions (\(model.questions.count))").font(.headline)
            ForEach(Array(model.questions.enumerated()), id: \.offset) { _, question in
                let inDiff = model.fileID(for: question) != nil
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        onJump(question)
                    } label: {
                        questionRow(question)
                    }
                    .buttonStyle(.plain)
                    .disabled(!inDiff)
                    .opacity(inDiff ? 1 : 0.5)
                    .help(inDiff ? "Show this question in the diff" : "This file isn't part of the current diff")
                    Button {
                        model.removeQuestion(question)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this question")
                    .padding(.top, 8)
                }
            }
        }
    }

    private func questionRow(_ question: Annotation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: AnnotationKind.question.icon).foregroundStyle(AnnotationKind.question.color)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(question.file) · \(question.lineLabel)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                Text(question.question ?? "").font(.callout.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isPending(question) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Claude is thinking…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(AnnotationCard.markdown(question.comment.isEmpty ? "No answer." : question.comment))
                        .font(.callout)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(AnnotationKind.question.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func review(_ stored: CompareModel.StoredReview) -> some View {
        let all = stored.review.annotations
        let annotations = all.filter { !(model.hideResolved && model.isResolved($0)) }
        let byFile = Dictionary(grouping: annotations, by: \.file)
        let files = byFile.keys.sorted()
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                KindCounts(annotations: all.filter { !model.isResolved($0) }, resolved: model.resolvedCount)
                Text(
                    "\(stored.command) · \(stored.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        + (stored.costUSD.map { String(format: " · $%.2f", $0) } ?? "")
                )
                .font(.caption).foregroundStyle(.secondary)
                if !stored.focus.isEmpty {
                    Text("Focus: \(stored.focus)").font(.caption).foregroundStyle(.secondary)
                }
                if model.reviewIsOutdated {
                    Label(
                        "The diff has changed since this review — comments may point at the wrong lines. Ask Claude again to refresh it.",
                        systemImage: "clock.badge.exclamationmark"
                    )
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

            if !all.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Comments (\(annotations.count))").font(.headline)
                        Spacer()
                        Toggle(
                            "Hide resolved",
                            isOn: Binding(
                                get: { model.hideResolved },
                                set: { model.hideResolved = $0 })
                        )
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .disabled(model.resolvedCount == 0 && !model.hideResolved)
                    }
                    ForEach(files, id: \.self) { file in
                        let fileAnnotations = byFile[file]!.sorted { $0.startLine < $1.startLine }
                        let inDiff = model.fileID(for: fileAnnotations[0]) != nil
                        VStack(alignment: .leading, spacing: 6) {
                            if !inDiff {
                                Text("This file isn't part of the current diff.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button {
                                onJump(fileAnnotations[0])
                            } label: {
                                Label(file, systemImage: "doc.text")
                                    .font(.callout.monospaced().weight(.semibold))
                                    .lineLimit(1).truncationMode(.head)
                            }
                            .buttonStyle(.link)
                            .disabled(!inDiff)
                            .help(inDiff ? "Jump to \(file)" : "This file isn't part of the current diff")
                            // Index-based identity: robust even if two comments are identical.
                            ForEach(Array(fileAnnotations.enumerated()), id: \.offset) { _, annotation in
                                let resolved = model.isResolved(annotation)
                                HStack(alignment: .top, spacing: 6) {
                                    Button {
                                        onJump(annotation)
                                    } label: {
                                        commentRow(annotation, resolved: resolved)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!inDiff)
                                    .opacity(inDiff ? (resolved ? 0.55 : 1) : 0.5)
                                    .help(
                                        inDiff
                                            ? "Show this comment in the diff"
                                            : "This file isn't part of the current diff")
                                    Button {
                                        model.toggleResolved(annotation)
                                    } label: {
                                        Image(systemName: resolved ? "checkmark.circle.fill" : "checkmark.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(resolved ? Color.green : Color.secondary)
                                    .help(resolved ? "Reopen this comment" : "Mark this comment as resolved")
                                    .padding(.top, 8)
                                }
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

    private func commentRow(_ annotation: Annotation, resolved: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: annotation.kind.icon).foregroundStyle(annotation.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(resolved ? "Resolved · " : "")\(annotation.kind.label) · \(annotation.side == .old ? "old " : "")\(annotation.lineLabel)"
                )
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
