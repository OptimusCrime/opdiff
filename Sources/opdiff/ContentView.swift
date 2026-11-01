import DiffCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: CompareModel
    @State private var selection: String?
    @State private var filter = ""
    @AppStorage("splitView") private var splitView = false

    var body: some View {
        Group {
            if model.repo == nil {
                WelcomeView(model: model)
            } else {
                NavigationSplitView {
                    FileListView(model: model, selection: $selection, filter: filter)
                        .searchable(text: $filter, placement: .sidebar, prompt: "Filter files")
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
                } detail: {
                    DiffListView(model: model, selection: $selection, splitView: splitView)
                }
                .toolbar { toolbar }
            }
        }
        .navigationTitle(model.repo?.lastPathComponent ?? "opdiff")
        .navigationSubtitle(model.repo == nil ? "" : "\(model.base)...\(model.head)")
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
            BranchPicker(title: "base", selection: $model.base, branches: model.branches)
            Image(systemName: "arrow.left").foregroundStyle(.secondary)
            BranchPicker(title: "compare", selection: $model.head, branches: model.branches)
            Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                .help("Swap base and compare (⇧⌘S)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle("Include uncommitted", isOn: $model.includeUncommitted)
                .toggleStyle(.checkbox)
                .disabled(!model.canIncludeUncommitted)
                .help(model.canIncludeUncommitted
                      ? "Include staged, unstaged and untracked changes in the working tree"
                      : "Only available when 'compare' is the checked-out branch (\(model.currentBranch ?? "none"))")
            Picker("Layout", selection: $splitView) {
                Image(systemName: "rectangle").help("Unified").tag(false)
                Image(systemName: "rectangle.split.2x1").help("Split").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Unified or split view")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh (⌘R)")
        }
    }
}

/// Searchable branch dropdown. Typing a ref that isn't listed (a tag, a SHA, HEAD~3) and
/// pressing Return uses it as-is.
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
            HStack(spacing: 4) {
                Text("\(title):").foregroundStyle(.secondary)
                Text(selection.isEmpty ? "select…" : selection).fontWeight(.semibold).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
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

struct WelcomeView: View {
    let model: CompareModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("opdiff").font(.largeTitle.bold().monospaced())
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
