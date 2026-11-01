import DiffCore
import SwiftUI

struct FileListView: View {
    let model: CompareModel
    @Binding var selection: String?
    let filter: String
    /// Folders the user has closed. Everything is expanded by default.
    @State private var collapsedDirs: Set<String> = []

    private var files: [FileDiff] {
        filter.isEmpty ? model.files : model.files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let tree = FileTreeNode.build(files)
        List(selection: $selection) {
            ForEach(tree) { node in
                TreeNodeView(node: node, model: model, collapsedDirs: $collapsedDirs,
                             forceExpanded: !filter.isEmpty)
            }
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
                        Button("Expand All Folders") { collapsedDirs = [] }
                        Button("Collapse All Folders") { collapsedDirs = Set(tree.flatMap(\.allDirectoryIDs)) }
                        Divider()
                        Button("Expand All Diffs") { model.expandAll() }
                        Button("Collapse All Diffs") { model.collapseAll() }
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

/// A folder or a file in the sidebar tree.
struct FileTreeNode: Identifiable {
    let id: String
    let name: String
    let children: [FileTreeNode]?  // nil for files
    let file: FileDiff?
    let additions: Int
    let deletions: Int

    var allDirectoryIDs: [String] {
        guard let children else { return [] }
        return [id] + children.flatMap(\.allDirectoryIDs)
    }

    private final class Dir {
        var dirs: [String: Dir] = [:]
        var files: [FileDiff] = []
    }

    static func build(_ files: [FileDiff]) -> [FileTreeNode] {
        let root = Dir()
        for file in files {
            var dir = root
            for component in file.path.split(separator: "/").dropLast().map(String.init) {
                if let next = dir.dirs[component] { dir = next } else {
                    let next = Dir(); dir.dirs[component] = next; dir = next
                }
            }
            dir.files.append(file)
        }
        return nodes(in: root, prefix: "")
    }

    private static func nodes(in dir: Dir, prefix: String) -> [FileTreeNode] {
        let folders = dir.dirs.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            // Collapse chains of single-child folders into one row, e.g. "Sources/opdiff".
            var name = key, sub = dir.dirs[key]!
            while sub.files.isEmpty, sub.dirs.count == 1, let (childName, child) = sub.dirs.first {
                name += "/" + childName
                sub = child
            }
            let path = prefix + name
            let children = nodes(in: sub, prefix: path + "/")
            return FileTreeNode(id: "dir:" + path, name: name, children: children, file: nil,
                                additions: children.reduce(0) { $0 + $1.additions },
                                deletions: children.reduce(0) { $0 + $1.deletions })
        }
        let files = dir.files
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { FileTreeNode(id: $0.id, name: ($0.path as NSString).lastPathComponent, children: nil,
                                file: $0, additions: $0.additions, deletions: $0.deletions) }
        return folders + files
    }
}

private struct TreeNodeView: View {
    let node: FileTreeNode
    let model: CompareModel
    @Binding var collapsedDirs: Set<String>
    let forceExpanded: Bool

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(children) { child in
                    TreeNodeView(node: child, model: model, collapsedDirs: $collapsedDirs,
                                 forceExpanded: forceExpanded)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.wrappedValue ? "folder" : "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(node.name).lineLimit(1).truncationMode(.head).layoutPriority(1)
                    Spacer(minLength: 4)
                    DiffStat(additions: node.additions, deletions: node.deletions, showBlocks: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .opacity(0.8)
                        .fixedSize()
                }
                .help(String(node.id.dropFirst(4)))
            }
        } else if let file = node.file {
            FileRow(file: file, name: node.name, viewed: model.isViewed(file))
                .tag(file.id)
        }
    }

    private var expanded: Binding<Bool> {
        Binding(
            get: { forceExpanded || !collapsedDirs.contains(node.id) },
            set: { open in
                if open { collapsedDirs.remove(node.id) } else { collapsedDirs.insert(node.id) }
            })
    }
}

private struct FileRow: View {
    let file: FileDiff
    let name: String
    let viewed: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(status: file.status)
            Text(name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(viewed ? .secondary : .primary)
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
