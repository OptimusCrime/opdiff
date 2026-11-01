import DiffCore
import SwiftUI

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
                            KindCounts(
                                annotations: stored.review.annotations.filter { !model.isResolved($0) },
                                resolved: model.resolvedCount)
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

struct KindCounts: View {
    let annotations: [Annotation]
    var resolved = 0

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AnnotationKind.allCases.filter { $0 != .question }, id: \.self) { kind in
                let count = annotations.filter { $0.kind == kind }.count
                if count > 0 {
                    Label("\(count) \(kind.label.lowercased())", systemImage: kind.icon)
                        .font(.caption)
                        .foregroundStyle(kind.color)
                }
            }
            if annotations.isEmpty {
                Text(resolved > 0 ? "All comments resolved" : "No comments").font(.caption).foregroundStyle(.secondary)
            }
            if resolved > 0, !annotations.isEmpty {
                Label("\(resolved) resolved", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ReviewBox<Content: View>: View {
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
