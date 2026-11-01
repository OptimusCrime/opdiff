import DiffCore
import SwiftUI

/// Toolbar button label shared by both pickers: "title: value ▾".
private struct PickerLabel: View {
    let title: String
    let value: String?
    var isCommit = false

    var body: some View {
        HStack(spacing: 4) {
            Text("\(title):").foregroundStyle(.secondary)
            if isCommit, value != nil {
                Image(systemName: "smallcircle.filled.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text(value ?? "select…")
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

/// Searchable branch dropdown. Typing a ref that isn't listed (a tag, a SHA, HEAD~3)
/// and pressing Return uses it as-is.
struct BranchPicker: View {
    let title: String
    @Binding var selection: String
    let branches: [String]
    @State private var isOpen = false
    @State private var query = ""

    private var matches: [String] {
        query.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button {
            query = ""
            isOpen.toggle()
        } label: {
            PickerLabel(title: title, value: selection.isEmpty ? nil : selection)
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                TextField("Find a branch or type a ref", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { choose(matches.first ?? query) }
                List(matches, id: \.self) { branch in
                    Button {
                        choose(branch)
                    } label: {
                        HStack {
                            Image(systemName: "checkmark").opacity(branch == selection ? 1 : 0)
                            Text(branch).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            .padding(10)
            .frame(width: 340, height: 380)
        }
    }

    private func choose(_ ref: String) {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if !ref.isEmpty { selection = ref }
        isOpen = false
    }
}

/// Searchable commit dropdown for commits mode. The base picker lists the branch's
/// history (and lets you switch branch); the compare picker lists only commits after base.
struct CommitPicker: View {
    enum Role { case base, compare }

    let title: String
    let selection: String
    let commits: [Commit]
    let model: CompareModel
    let role: Role
    let onSelect: (String) -> Void
    @State private var isOpen = false
    @State private var query = ""

    private var matches: [Commit] {
        guard !query.isEmpty else { return commits }
        return commits.filter {
            $0.subject.localizedCaseInsensitiveContains(query)
                || $0.sha.hasPrefix(query.lowercased())
                || $0.author.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedCommit: Commit? {
        selection.isEmpty ? nil : commits.first { $0.sha == selection } ?? model.commit(for: selection)
    }

    var body: some View {
        Button {
            query = ""
            isOpen.toggle()
        } label: {
            PickerLabel(
                title: title,
                value: selectedCommit.map { "\($0.hash) \($0.subject)" }
                    ?? (selection.isEmpty ? nil : model.displayName(selection)),
                isCommit: true)
        }
        .help(selectedCommit.map { "\($0.hash) \($0.subject)\n\($0.author) · \($0.date)" } ?? "")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                header
                TextField("Find a commit by message, hash or author", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = matches.first { choose(first.sha) } }
                List(matches) { commit in
                    Button {
                        choose(commit.sha)
                    } label: {
                        row(commit)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .overlay {
                    if commits.isEmpty {
                        Text(role == .base ? "No commits on this branch." : "No commits after the base commit.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(width: 460, height: 420)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch role {
        case .base:
            HStack(spacing: 4) {
                Text("Commits on").foregroundStyle(.secondary)
                Menu(model.commitBranch) {
                    ForEach(model.branches, id: \.self) { branch in
                        Button(branch) {
                            isOpen = false
                            Task { await model.selectCommitBranch(branch) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.callout)
        case .compare:
            Text("Commits after \(model.displayName(model.base)) on \(model.commitBranch)")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row(_ commit: Commit) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "checkmark").opacity(commit.sha == selection ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject).lineLimit(1)
                HStack(spacing: 6) {
                    Text(commit.hash).font(.caption.monospaced())
                    Text("\(commit.author) · \(commit.date)").font(.caption).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if commit.sha == model.base { RefTag(text: "base") }
            if commit.sha == model.head { RefTag(text: "compare") }
        }
        .contentShape(Rectangle())
    }

    private func choose(_ sha: String) {
        onSelect(sha)
        isOpen = false
    }
}

private struct RefTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}
