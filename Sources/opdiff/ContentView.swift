import DiffCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: CompareModel
    @State private var selection: String?
    @State private var filter = ""
    @State private var showReview = false
    @AppStorage("reviewPaneWidth") private var reviewPaneWidth = 360.0
    @State private var jumpRequest: JumpRequest?
    @AppStorage("splitView") private var splitView = false
    @AppStorage("wrapLines") private var wrapLines = true

    var body: some View {
        Group {
            if model.repo == nil, model.isOpening {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.repo == nil {
                WelcomeView(model: model)
            } else {
                NavigationSplitView {
                    FileListView(model: model, selection: $selection, filter: filter)
                        .searchable(text: $filter, placement: .sidebar, prompt: "Filter files")
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
                } detail: {
                    // A plain side pane rather than `.inspector`: the inspector's ScrollView
                    // hit-tested its buttons ~one toolbar height above where they were drawn,
                    // so clicks landed on the wrong comment (or on nothing).
                    HStack(spacing: 0) {
                        DiffListView(model: model, selection: $selection, splitView: splitView, wrapLines: wrapLines,
                                     jumpRequest: jumpRequest) {
                            showReview = true
                        }
                        if showReview {
                            PaneDivider(width: $reviewPaneWidth)
                            ReviewInspector(model: model, onClose: { showReview = false }) { annotation in
                                jumpRequest = JumpRequest(annotation: annotation)
                            }
                                .frame(width: reviewPaneWidth)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
                .toolbar { toolbar }
                // Show the review panel when a review starts or a new one arrives.
                .onChange(of: model.isReviewing) { _, running in if running { showReview = true } }
                .onChange(of: model.storedReview?.createdAt) { _, date in if date != nil { showReview = true } }
            }
        }
        .navigationTitle(model.repo?.lastPathComponent ?? "OptimusDiff")
        .navigationSubtitle(model.base.isEmpty || model.head.isEmpty ? "" : "\(model.displayName(model.base))...\(model.displayName(model.head))")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.openRepository(url) }
            return true
        }
        .task { await model.handleLaunch() }
        .task(id: model.compareKey) { await model.loadDiff() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Compare", selection: Binding(get: { model.mode },
                                                 set: { mode in Task { await model.setMode(mode) } })) {
                Text("Branches").tag(CompareMode.branches)
                Text("Commits").tag(CompareMode.commits)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Compare two branches, or two commits on one branch")

            if model.mode == .branches {
                BranchPicker(title: "base", selection: $model.base, branches: model.branches)
                Image(systemName: "arrow.left").foregroundStyle(.secondary)
                BranchPicker(title: "compare", selection: $model.head, branches: model.branches)
                Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap base and compare (⇧⌘S)")
            } else {
                CommitPicker(title: "base", selection: model.base, commits: model.history, model: model,
                             role: .base) { sha in Task { await model.selectBaseCommit(sha) } }
                Image(systemName: "arrow.left").foregroundStyle(.secondary)
                CommitPicker(title: "compare", selection: model.head, commits: model.commitsAfterBase, model: model,
                             role: .compare) { sha in model.selectCompareCommit(sha) }
                    .disabled(model.base.isEmpty)
                    .help(model.base.isEmpty ? "Select a base commit first" : "")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Shows the effective state: unchecked when it can't apply (e.g. compare is a commit).
            Toggle("Include uncommitted", isOn: Binding(
                get: { model.effectiveUncommitted },
                set: { model.includeUncommitted = $0 }))
                .toggleStyle(.checkbox)
                .disabled(!model.canIncludeUncommitted)
                .help(model.canIncludeUncommitted
                      ? "Include staged, unstaged and untracked changes in the working tree"
                      : "Only available when 'compare' is the checked-out branch (\(model.currentBranch ?? "none"))")
            AskClaudeButton(model: model)
            Picker("Layout", selection: $splitView) {
                Image(systemName: "rectangle").help("Unified").tag(false)
                Image(systemName: "rectangle.split.2x1").help("Split").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Unified or split view")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh (⌘R)")
            Button { showReview.toggle() } label: {
                Label("Claude Review", systemImage: "sidebar.right")
            }
            .help(showReview ? "Hide the Claude review panel" : "Show the Claude review panel")
        }
    }
}

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
        Button { query = ""; isOpen.toggle() } label: {
            PickerLabel(title: title, value: selection.isEmpty ? nil : selection)
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                TextField("Find a branch or type a ref", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { choose(matches.first ?? query) }
                List(matches, id: \.self) { branch in
                    Button { choose(branch) } label: {
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
        Button { query = ""; isOpen.toggle() } label: {
            PickerLabel(title: title,
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
                    Button { choose(commit.sha) } label: { row(commit) }
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

struct WelcomeView: View {
    let model: CompareModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("OptimusDiff").font(.largeTitle.bold())
            Text("Review every change between two branches before you open a pull request.")
                .foregroundStyle(.secondary)
            Button("Open Repository…") { model.chooseRepository() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if !model.recentRepos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.headline)
                    ForEach(model.recentRepos, id: \.self) { path in
                        Button {
                            Task { await model.openRepository(URL(fileURLWithPath: path)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).fontWeight(.medium)
                                Text(path).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            Text("Tip: drop a folder here, or run `opdiff` inside a repository.")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
