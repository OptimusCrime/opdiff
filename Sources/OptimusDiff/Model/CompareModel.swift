import AppKit
import DiffCore
import SwiftUI

enum CompareMode: Hashable {
    case branches
    /// A range of commits on one branch.
    case commits
    /// One commit on its own. `head` is the commit and `base` its first parent (or the empty tree).
    case commit
}

@MainActor @Observable
final class CompareModel {
    private(set) var repo: URL?
    private(set) var branches: [String] = []
    private(set) var currentBranch: String?
    var base = ""
    var head = ""
    var mode: CompareMode = .branches
    /// What `effectiveScope` uses when compare is the checked-out branch (see ChangeScope.swift).
    var changeScope: ChangeScope = .all

    /// Set only here and in CompareModel+Features (context reloads).
    var files: [FileDiff] = []
    private(set) var commits: [Commit] = []
    private(set) var mergeBase: String?
    private(set) var isLoading = false
    var errorMessage: String?

    var collapsed: Set<String> = []
    private(set) var viewed: Set<String> = []
    var expandedLarge: Set<String> = []
    private(set) var recentRepos: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []

    /// Syntax highlighting results, filled lazily as files scroll into view.
    private(set) var highlights: [String: HighlightedFile] = [:]

    /// True while a repository passed on the command line is being opened.
    private(set) var isOpening = false

    // Commits mode
    /// The branch whose history is listed in commits and single commit mode.
    var commitBranch = ""
    /// Recent commits on `commitBranch` (choices for base), newest first.
    var history: [Commit] = []
    /// Commits after `base` on `commitBranch` (choices for compare), newest first.
    var commitsAfterBase: [Commit] = []
    /// Branch selection to restore when leaving commits mode.
    var savedBranchSelection: (base: String, head: String)?

    // Claude review
    var reviewStatus: ReviewStatus = .idle
    var storedReview: StoredReview?
    /// Stable hash of the current diff; a saved review is outdated when it doesn't match.
    var diffFingerprint = ""
    var annotationLayouts: [String: AnnotationLayout] = [:]
    /// Annotations grouped by the diff file they resolve to (see AnnotationFileResolver).
    var annotationsByFile: [String: [Annotation]] = [:]
    /// Annotation id → file id, for jumping to a comment.
    var annotationFileIDs: [String: String] = [:]
    /// Briefly highlighted after jumping to it.
    var flashedAnnotationID: String?
    var recentClaudeCommands: [String] = UserDefaults.standard.stringArray(forKey: "claudeCommands") ?? []
    /// What the running review is about, e.g. "main...feature via claude".
    var reviewTarget: String?
    var reviewRun: ClaudeReviewRun?
    var reviewLoadedKey: String?

    /// Passed per git command; the user's global git config is left alone.
    var diffAlgorithm: DiffAlgorithm =
        DiffAlgorithm(rawValue: UserDefaults.standard.string(forKey: "diffAlgorithm") ?? "") ?? .myers
    {
        didSet { UserDefaults.standard.set(diffAlgorithm.rawValue, forKey: "diffAlgorithm") }
    }

    /// Lines selected by clicking (shift-click extends), for copying.
    var lineSelection: LineSelection?

    // MARK: View options (persisted)

    var splitView = UserDefaults.standard.bool(forKey: "splitView") {
        didSet {
            UserDefaults.standard.set(splitView, forKey: "splitView")
            lineSelection = nil
        }
    }
    /// git diff -w.
    var ignoreWhitespace = UserDefaults.standard.bool(forKey: "ignoreWhitespace") {
        didSet { UserDefaults.standard.set(ignoreWhitespace, forKey: "ignoreWhitespace") }
    }
    /// Reload when files in the repository change.
    var autoRefresh = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh")
            updateWatcher()
        }
    }
    /// Leave resolved review comments out of the diff and the comment list.
    var hideResolved = UserDefaults.standard.bool(forKey: "hideResolved") {
        didSet {
            UserDefaults.standard.set(hideResolved, forKey: "hideResolved")
            rebuildAnnotationLayouts()
        }
    }

    // MARK: Feature state (see the CompareModel+*.swift extensions)

    /// Lines of context per file after "More context" / "Full file" (git's default is 3).
    var contextLines: [String: Int] = [:]
    @ObservationIgnored var contextScope = ""
    /// Scroll request for the diff view.
    var jumpRequest: JumpRequest?
    /// Where keyboard navigation continues from when no lines are selected.
    @ObservationIgnored var navPosition: NavPosition?
    @ObservationIgnored var lastCommentID: String?

    var findVisible = false
    var findFocusToken = 0
    var searchQuery = "" { didSet { if searchQuery != oldValue { scheduleSearch(jump: true) } } }
    var searchMatches: [SearchMatch] = []
    var searchHits: [String: [LineID: [Range<Int>]]] = [:]
    var currentMatchIndex: Int?
    @ObservationIgnored var searchTask: Task<Void, Never>?

    /// Questions asked about selected lines, with Claude's answers (saved per comparison).
    var questions: [Annotation] = []
    var pendingQuestionIDs: Set<String> = []
    @ObservationIgnored var questionRuns: [String: ClaudeReviewRun] = [:]
    var questionDraft: QuestionDraft?
    @ObservationIgnored var questionsLoadedKey: String?

    @ObservationIgnored var watcher: RepoWatcher?
    @ObservationIgnored var changedPaths: Set<String> = []
    @ObservationIgnored var watchDebounce: Task<Void, Never>?
    /// The diff window, so keyboard shortcuts only act there.
    @ObservationIgnored weak var mainWindow: NSWindow?

    private var reloadToken = 0
    private var launch: LaunchOptions?

    init(launch: LaunchOptions) { self.launch = launch }

    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// The view re-runs `loadDiff()` whenever this changes.
    var compareKey: String {
        "\(repo?.path ?? "")|\(mode)|\(base)|\(head)|\(effectiveScope.rawValue)|\(diffAlgorithm.rawValue)|\(ignoreWhitespace)|\(reloadToken)"
    }

    // MARK: Loading

    func handleLaunch() async {
        guard let options = launch else { return }
        launch = nil
        guard let url = options.repo else { return }
        changeScope = options.changeScope
        isOpening = true
        await openRepository(url, base: options.base, head: options.head, reportErrors: options.explicitRepo)
        if let count = options.commitCount { await showRecentCommits(count) }
        isOpening = false
    }

    func openRepository(_ url: URL, base: String? = nil, head: String? = nil, reportErrors: Bool = true) async {
        do {
            let info = try await Task.detached { try Git.repositoryInfo(at: url) }.value
            repo = info.root
            branches = info.branches
            currentBranch = info.currentBranch
            files = []
            commits = []
            collapsed = []
            viewed = []
            expandedLarge = []
            highlights = [:]
            history = []
            commitsAfterBase = []
            savedBranchSelection = nil
            errorMessage = nil
            addRecent(info.root.path)
            updateWatcher()

            // Two refs that aren't branches (e.g. `opdiff <sha1> <sha2>`): open in commits mode.
            if let base, let head, !isBranch(base), !isBranch(head) {
                mode = .commits
                commitBranch = info.currentBranch ?? "HEAD"
                history = await fetchHistory(commitBranch)
                commitsAfterBase = await fetchHistory("\(base)..\(commitBranch)")
                (self.base, self.head) = (base, head)
            } else {
                mode = .branches
                self.head = head ?? info.currentBranch ?? info.branches.first ?? ""
                self.base = base ?? info.defaultBase ?? ""
            }
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    func loadDiff() async {
        guard let repo, !base.isEmpty, !head.isEmpty else {
            files = []
            commits = []
            mergeBase = nil
            refreshReviewForCurrentDiff()
            return
        }
        let (base, head, scope, algorithm, ws, single) = (
            base, head, effectiveScope, diffAlgorithm, ignoreWhitespace, mode == .commit
        )
        isLoading = true
        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> Comparison in
                if single {
                    return try Git.singleCommit(
                        repo: repo, commit: head, parent: base, algorithm: algorithm, ignoreWhitespace: ws)
                }
                return scope == .uncommitted
                    ? try Git.uncommitted(repo: repo, algorithm: algorithm, ignoreWhitespace: ws)
                    : try Git.compare(
                        repo: repo, base: base, head: head, includeWorkingTree: scope == .all,
                        algorithm: algorithm, ignoreWhitespace: ws)
            }.value
            guard !Task.isCancelled else { return }
            files = result.files.sorted(by: Self.treeOrder)
            commits = result.commits
            mergeBase = result.mergeBase
            errorMessage = nil
            // Keep the selection across refreshes while it still points at existing rows.
            if let s = lineSelection,
                !(files.first { $0.id == s.fileID }.map { s.range.upperBound < rows(of: $0, split: s.split).count }
                    ?? false)
            {
                lineSelection = nil
            }
            await reapplyContext()
        } catch {
            guard !Task.isCancelled else { return }
            files = []
            commits = []
            mergeBase = nil
            errorMessage = error.localizedDescription
        }
        refreshReviewForCurrentDiff()
        scheduleSearch(jump: false)
        isLoading = false
    }

    /// Same order as the sidebar tree: folders before files at each level, then natural sort.
    static func treeOrder(_ a: FileDiff, _ b: FileDiff) -> Bool {
        let ac = a.path.split(separator: "/")
        let bc = b.path.split(separator: "/")
        for i in 0..<min(ac.count, bc.count) where ac[i] != bc[i] {
            let aIsDir = i < ac.count - 1
            let bIsDir = i < bc.count - 1
            if aIsDir != bIsDir { return aIsDir }
            return String(ac[i]).localizedStandardCompare(String(bc[i])) == .orderedAscending
        }
        return ac.count < bc.count
    }

    func refresh() {
        guard let repo else { return }
        Task {
            // Pick up new branches / branch switches, but keep the selected refs.
            if let info = try? await Task.detached(operation: { try Git.repositoryInfo(at: repo) }).value {
                branches = info.branches
                currentBranch = info.currentBranch
            }
            if mode != .branches {  // new commits may exist
                let wasLatest = history.first?.sha == head
                history = await fetchHistory(commitBranch)
                if mode == .commits, !base.isEmpty {
                    commitsAfterBase = await fetchHistory("\(base)..\(commitBranch)")
                }
                // Follow the branch tip, and don't get stuck on a commit that was amended or rebased away.
                if mode == .commit, wasLatest || !history.contains(where: { $0.sha == head }),
                    let latest = history.first
                {
                    await selectSingleCommit(latest)
                }
            }
            reloadToken += 1
        }
    }

    func swap() {
        guard mode == .branches, !onlyUncommitted else { return }  // in commits mode, base must come first
        (base, head) = (head, base)
    }

    // MARK: Refs

    func isBranch(_ ref: String) -> Bool { branches.contains(ref) }

    /// Branch names as-is; commit hashes shortened.
    func displayName(_ ref: String) -> String {
        guard !ref.isEmpty, !isBranch(ref), Self.looksLikeHash(ref) else { return ref }
        return String(ref.prefix(8))
    }

    /// The commit a ref points to, if it's in the loaded history.
    func commit(for ref: String) -> Commit? {
        guard !ref.isEmpty, !isBranch(ref) else { return nil }
        let ref = ref.lowercased()
        return history.first { $0.sha.hasPrefix(ref) }
    }

    static func looksLikeHash(_ ref: String) -> Bool {
        ref.count >= 7 && ref.allSatisfy(\.isHexDigit)
    }

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

    /// Only the changed lines count: showing more context keeps a file viewed.
    private func viewedKey(_ f: FileDiff) -> String { "\(f.path)#\(f.changeHash)" }

    func isViewed(_ f: FileDiff) -> Bool { viewed.contains(viewedKey(f)) }
    func isCollapsed(_ f: FileDiff) -> Bool { collapsed.contains(f.id) }
    func isLargeHidden(_ f: FileDiff) -> Bool { f.lineCount > 1000 && !expandedLarge.contains(f.id) }
    var viewedCount: Int { files.filter(isViewed).count }

    func setViewed(_ f: FileDiff, _ value: Bool) {
        // Like GitHub: marking a file as viewed collapses it.
        if value {
            viewed.insert(viewedKey(f))
            collapsed.insert(f.id)
        } else {
            viewed.remove(viewedKey(f))
            collapsed.remove(f.id)
        }
    }

    func toggleCollapsed(_ f: FileDiff) {
        if collapsed.contains(f.id) { collapsed.remove(f.id) } else { collapsed.insert(f.id) }
    }

    // MARK: Syntax highlighting

    private func highlightKey(_ f: FileDiff, dark: Bool) -> String { "\(f.id)#\(f.contentHash)#\(dark)" }

    func highlighted(_ f: FileDiff, dark: Bool) -> HighlightedFile? { highlights[highlightKey(f, dark: dark)] }

    func ensureHighlighted(_ f: FileDiff, dark: Bool) async {
        let key = highlightKey(f, dark: dark)
        guard highlights[key] == nil else { return }
        guard let result = await SyntaxHighlighter.shared.highlight(f, dark: dark), !Task.isCancelled else { return }
        highlights[key] = result
    }

    func expandLarge(_ f: FileDiff) { expandedLarge.insert(f.id) }
    func collapseAll() { collapsed = Set(files.map(\.id)) }
    func expandAll() { collapsed = [] }

    func fileURL(_ f: FileDiff) -> URL? { repo?.appendingPathComponent(f.path) }
}
