import DiffCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: CompareModel
    @State private var selection: String?
    @State private var filter = ""
    @State private var showReview = false
    @AppStorage("reviewPaneWidth") private var reviewPaneWidth = 360.0
    @AppStorage("wrapLines") private var wrapLines = true
    @State private var keyMonitor: Any?

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
                        VStack(spacing: 0) {
                            if model.findVisible {
                                FindBar(model: model)
                                Divider()
                            }
                            DiffListView(model: model, selection: $selection, wrapLines: wrapLines) {
                                showReview = true
                            }
                        }
                        if showReview {
                            PaneDivider(width: $reviewPaneWidth)
                            ReviewInspector(model: model, onClose: { showReview = false }) { annotation in
                                model.jump(to: annotation)
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
                .sheet(item: $model.questionDraft) { draft in QuestionSheet(model: model, draft: draft) }
            }
        }
        .background(WindowReader { model.mainWindow = $0 })
        .onAppear(perform: installKeyMonitor)
        .navigationTitle(model.repo?.lastPathComponent ?? "OptimusDiff")
        .navigationSubtitle(
            model.base.isEmpty || model.head.isEmpty
                ? "" : "\(model.displayName(model.base))...\(model.displayName(model.head))"
        )
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
            Picker(
                "Compare",
                selection: Binding(
                    get: { model.mode },
                    set: { mode in Task { await model.setMode(mode) } })
            ) {
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
                Button {
                    model.swap()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Swap base and compare (⇧⌘S)")
            } else {
                CommitPicker(
                    title: "base", selection: model.base, commits: model.history, model: model,
                    role: .base
                ) { sha in Task { await model.selectBaseCommit(sha) } }
                Image(systemName: "arrow.left").foregroundStyle(.secondary)
                CommitPicker(
                    title: "compare", selection: model.head, commits: model.commitsAfterBase, model: model,
                    role: .compare
                ) { sha in model.selectCompareCommit(sha) }
                .disabled(model.base.isEmpty)
                .help(model.base.isEmpty ? "Select a base commit first" : "")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Shows the effective state: unchecked when it can't apply (e.g. compare is a commit).
            Toggle(
                "Include uncommitted",
                isOn: Binding(
                    get: { model.effectiveUncommitted },
                    set: { model.includeUncommitted = $0 })
            )
            .toggleStyle(.checkbox)
            .disabled(!model.canIncludeUncommitted)
            .help(
                model.canIncludeUncommitted
                    ? "Include staged, unstaged and untracked changes in the working tree"
                    : "Only available when 'compare' is the checked-out branch (\(model.currentBranch ?? "none"))")
            AskClaudeButton(model: model)
            Picker("Layout", selection: $model.splitView) {
                Image(systemName: "rectangle").help("Unified").tag(false)
                Image(systemName: "rectangle.split.2x1").help("Split").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Unified or split view")
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            Button {
                showReview.toggle()
            } label: {
                Label("Claude Review", systemImage: "sidebar.right")
            }
            .help(showReview ? "Hide the Claude review panel" : "Show the Claude review panel")
        }
    }
}

extension ContentView {
    /// Single-letter shortcuts (j/k, n/p, v, o, a); the model ignores them while typing.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { model.handleKey(event) } ? nil : event
        }
    }
}
