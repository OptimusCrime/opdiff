import AppKit
import DiffCore
import SwiftUI

/// Values passed on the command line, e.g. by `opdiff`:
///   opdiff --repo <path> [--base <ref>] [--head <ref>] [--uncommitted]
struct LaunchOptions {
    var repo: URL?
    var base: String?
    var head: String?
    var uncommitted = false
    var explicitRepo = false

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            let value: String? = i + 1 < args.count ? args[i + 1] : nil
            switch args[i] {
            case "--repo": if let v = value { o.repo = URL(fileURLWithPath: v); o.explicitRepo = true; i += 1 }
            case "--base": if let v = value { o.base = v; i += 1 }
            case "--head", "--compare": if let v = value { o.head = v; i += 1 }
            case "--uncommitted", "-u": o.uncommitted = true
            default: break
            }
            i += 1
        }
        // `swift run` from inside a repo: use the working directory.
        let cwd = FileManager.default.currentDirectoryPath
        if o.repo == nil, cwd != "/" { o.repo = URL(fileURLWithPath: cwd) }
        return o
    }
}

@MainActor @Observable
final class CompareModel {
    private(set) var repo: URL?
    private(set) var branches: [String] = []
    private(set) var currentBranch: String?
    var base = ""
    var head = ""
    var includeUncommitted = false

    private(set) var files: [FileDiff] = []
    private(set) var commits: [Commit] = []
    private(set) var mergeBase: String?
    private(set) var isLoading = false
    var errorMessage: String?

    private(set) var collapsed: Set<String> = []
    private(set) var viewed: Set<String> = []
    private(set) var expandedLarge: Set<String> = []
    private(set) var recentRepos: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []

    private var reloadToken = 0
    private var launch: LaunchOptions?

    init(launch: LaunchOptions) { self.launch = launch }

    var canIncludeUncommitted: Bool { !head.isEmpty && head == currentBranch }
    var effectiveUncommitted: Bool { includeUncommitted && canIncludeUncommitted }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// The view re-runs `loadDiff()` whenever this changes.
    var compareKey: String {
        "\(repo?.path ?? "")|\(base)|\(head)|\(effectiveUncommitted)|\(reloadToken)"
    }

    // MARK: Loading

    func handleLaunch() async {
        guard let options = launch else { return }
        launch = nil
        guard let url = options.repo else { return }
        includeUncommitted = options.uncommitted
        await openRepository(url, base: options.base, head: options.head, reportErrors: options.explicitRepo)
    }

    func openRepository(_ url: URL, base: String? = nil, head: String? = nil, reportErrors: Bool = true) async {
        do {
            let info = try await Task.detached { try Git.repositoryInfo(at: url) }.value
            repo = info.root
            branches = info.branches
            currentBranch = info.currentBranch
            self.head = head ?? info.currentBranch ?? info.branches.first ?? ""
            self.base = base ?? info.defaultBase ?? ""
            files = []; commits = []; collapsed = []; viewed = []; expandedLarge = []
            errorMessage = nil
            addRecent(info.root.path)
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    func loadDiff() async {
        guard let repo, !base.isEmpty, !head.isEmpty else { files = []; commits = []; return }
        let (base, head, uncommitted) = (base, head, effectiveUncommitted)
        isLoading = true
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Git.compare(repo: repo, base: base, head: head, includeWorkingTree: uncommitted)
            }.value
            guard !Task.isCancelled else { return }
            files = result.files
            commits = result.commits
            mergeBase = result.mergeBase
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            files = []; commits = []; mergeBase = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() {
        guard let repo else { return }
        Task {
            // Pick up new branches / branch switches, but keep the selected refs.
            if let info = try? await Task.detached(operation: { try Git.repositoryInfo(at: repo) }).value {
                branches = info.branches
                currentBranch = info.currentBranch
            }
            reloadToken += 1
        }
    }

    func swap() { (base, head) = (head, base) }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await openRepository(url) }
        }
    }

    private func addRecent(_ path: String) {
        recentRepos.removeAll { $0 == path }
        recentRepos.insert(path, at: 0)
        recentRepos = Array(recentRepos.prefix(8))
        UserDefaults.standard.set(recentRepos, forKey: "recentRepos")
    }

    // MARK: Per-file UI state

    private func viewedKey(_ f: FileDiff) -> String { "\(f.path)#\(f.contentHash)" }

    func isViewed(_ f: FileDiff) -> Bool { viewed.contains(viewedKey(f)) }
    func isCollapsed(_ f: FileDiff) -> Bool { collapsed.contains(f.id) }
    func isLargeHidden(_ f: FileDiff) -> Bool { f.lineCount > 1000 && !expandedLarge.contains(f.id) }
    var viewedCount: Int { files.filter(isViewed).count }

    func setViewed(_ f: FileDiff, _ value: Bool) {
        // Like GitHub: marking a file as viewed collapses it.
        if value { viewed.insert(viewedKey(f)); collapsed.insert(f.id) }
        else { viewed.remove(viewedKey(f)); collapsed.remove(f.id) }
    }

    func toggleCollapsed(_ f: FileDiff) {
        if collapsed.contains(f.id) { collapsed.remove(f.id) } else { collapsed.insert(f.id) }
    }

    func expandLarge(_ f: FileDiff) { expandedLarge.insert(f.id) }
    func collapseAll() { collapsed = Set(files.map(\.id)) }
    func expandAll() { collapsed = [] }

    func fileURL(_ f: FileDiff) -> URL? { repo?.appendingPathComponent(f.path) }
}
