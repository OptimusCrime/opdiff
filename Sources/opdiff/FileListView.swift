import DiffCore
import SwiftUI

struct FileListView: View {
    let model: CompareModel
    @Binding var selection: String?
    let filter: String

    private var files: [FileDiff] {
        filter.isEmpty ? model.files : model.files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List(files, selection: $selection) { file in
            FileRow(file: file, viewed: model.isViewed(file))
        }
        .overlay {
            if model.files.isEmpty, !model.isLoading {
                ContentUnavailableView("No changed files", systemImage: "doc.text.magnifyingglass")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.files.isEmpty {
                HStack {
                    Text("\(model.viewedCount) / \(model.files.count) viewed")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Expand All") { model.expandAll() }
                        Button("Collapse All") { model.collapseAll() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

private struct FileRow: View {
    let file: FileDiff
    let viewed: Bool

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 8) {
            StatusBadge(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).foregroundStyle(viewed ? .secondary : .primary)
                if !dir.isEmpty {
                    Text(dir).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if viewed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            }
            DiffStat(additions: file.additions, deletions: file.deletions, showBlocks: false)
                .font(.caption.monospacedDigit())
                .fixedSize()
        }
        .help(file.path)
    }
}

struct StatusBadge: View {
    let status: FileStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.bold().monospaced())
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .help(label)
    }

    private var color: Color {
        switch status {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed: .blue
        case .copied: .purple
        }
    }

    private var label: String {
        switch status {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}

/// "+12 −4 ■■■□□" like GitHub.
struct DiffStat: View {
    let additions: Int
    let deletions: Int
    var showBlocks = true

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 || deletions == 0 { Text("+\(additions)").foregroundStyle(.green) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(.red) }
            if showBlocks {
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(blockColor(i))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
    }

    private func blockColor(_ i: Int) -> Color {
        let total = additions + deletions
        guard total > 0 else { return .secondary.opacity(0.3) }
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        let red = min(5 - green, Int((Double(deletions) / Double(total) * 5).rounded()))
        if i < green { return .green }
        if i < green + red { return .red }
        return .secondary.opacity(0.3)
    }
}
