import DiffCore
import SwiftUI

extension AnnotationKind {
    var color: Color {
        switch self {
        case .important: .orange
        case .attention: .yellow
        case .info: .blue
        case .question: .purple
        }
    }

    var icon: String {
        switch self {
        case .important: "exclamationmark.triangle.fill"
        case .attention: "eye.fill"
        case .info: "info.circle.fill"
        case .question: "questionmark.bubble.fill"
        }
    }

    var label: String {
        switch self {
        case .important: "Important"
        case .attention: "Attention"
        case .info: "Info"
        case .question: "Question"
        }
    }
}

/// What the buttons on a comment card do.
struct CardActions {
    let toggleResolved: (Annotation) -> Void
    let remove: (Annotation) -> Void
    let cancel: (Annotation) -> Void
}

struct AnnotationCard: View {
    let annotation: Annotation
    var note: String?
    var isFlashing = false
    var isResolved = false
    var isPending = false
    var actions: CardActions?

    var body: some View {
        let kind = annotation.kind
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isResolved ? "checkmark.circle.fill" : kind.icon).foregroundStyle(kind.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isResolved ? "Resolved" : kind.label).font(.caption.weight(.bold)).foregroundStyle(kind.color)
                    Text(
                        "\(kind == .question ? "You" : "Claude") · \(annotation.side == .old ? "old " : "")\(annotation.lineLabel)"
                            + (note.map { " · \($0)" } ?? "")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    buttons
                }
                content
            }
        }
        .opacity(isResolved ? 0.6 : 1)
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

    @ViewBuilder
    private var content: some View {
        if annotation.kind == .question {
            Text(annotation.question ?? "")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if isPending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Claude is thinking…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else if annotation.comment.isEmpty {
                Text("No answer — the request was interrupted.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(Self.markdown(annotation.comment))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        } else {
            Text(annotation.comment)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if let actions {
            HStack(spacing: 10) {
                if annotation.kind == .question {
                    if isPending { Button("Stop") { actions.cancel(annotation) } }
                    Button {
                        actions.remove(annotation)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Remove this question")
                } else {
                    Button(isResolved ? "Reopen" : "Resolve") { actions.toggleResolved(annotation) }
                        .help(isResolved ? "Mark this comment as not resolved" : "Mark this comment as resolved")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    /// Claude's answers use inline Markdown (code, bold, links); line breaks are kept.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
