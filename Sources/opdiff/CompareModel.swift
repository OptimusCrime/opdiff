import AppKit
import CryptoKit
import DiffCore
import SwiftUI

/// Values passed on the command line, e.g. by `opdiff`:
///   opdiff --repo <path> [--base <ref>] [--head <ref>] [--committed-only]
struct LaunchOptions {
    var repo: URL?
    var base: String?
    var head: String?
    var uncommitted = true
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
            case "--committed-only", "-c": o.uncommitted = false
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

enum CompareMode: Hashable { case branches, commits }

@MainActor @Observable
final class CompareModel {
    private(set) var repo: URL?
    private(set) var branches: [String] = []
    private(set) var currentBranch: String?
    var base = ""
    var head = ""
    private(set) var mode: CompareMode = .branches
    var includeUncommitted = true

    private(set) var files: [FileDiff] = []
    private(set) var commits: [Commit] = []
    private(set) var mergeBase: String?
    private(set) var isLoading = false
    var errorMessage: String?

    private(set) var collapsed: Set<String> = []
    private(set) var viewed: Set<String> = []
    private(set) var expandedLarge: Set<String> = []
    private(set) var recentRepos: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []

    /// Syntax highlighting results, filled lazily as files scroll into view.
    private(set) var highlights: [String: HighlightedFile] = [:]

    /// True while a repository passed on the command line is being opened.
    private(set) var isOpening = false

    // Commits mode
    /// The branch whose history is listed in commits mode.
    private(set) var commitBranch = ""
    /// Recent commits on `commitBranch` (choices for base), newest first.
    private(set) var history: [Commit] = []
    /// Commits after `base` on `commitBranch` (choices for compare), newest first.
    private(set) var commitsAfterBase: [Commit] = []
    /// Branch selection to restore when leaving commits mode.
    private var savedBranchSelection: (base: String, head: String)?

    // Claude review
    private(set) var reviewStatus: ReviewStatus = .idle
    private(set) var storedReview: StoredReview?
    /// Stable hash of the current diff; a saved review is outdated when it doesn't match.
    private(set) var diffFingerprint = ""
    private(set) var annotationLayouts: [String: AnnotationLayout] = [:]
    /// Annotations grouped by the diff file they resolve to (see AnnotationFileResolver).
    private(set) var annotationsByFile: [String: [Annotation]] = [:]
    /// Annotation id → file id, for jumping to a comment.
    private(set) var annotationFileIDs: [String: String] = [:]
    /// Briefly highlighted after jumping to it.
    private(set) var flashedAnnotationID: String?
    private(set) var recentClaudeCommands: [String] = UserDefaults.standard.stringArray(forKey: "claudeCommands") ?? []
    /// What the running review is about, e.g. "main...feature via pclaude".
    private(set) var reviewTarget: String?
    private var reviewRun: ClaudeReviewRun?
    private var reviewLoadedKey: String?

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
        isOpening = true
        await openRepository(url, base: options.base, head: options.head, reportErrors: options.explicitRepo)
        isOpening = false
    }

    func openRepository(_ url: URL, base: String? = nil, head: String? = nil, reportErrors: Bool = true) async {
        do {
            let info = try await Task.detached { try Git.repositoryInfo(at: url) }.value
            repo = info.root
            branches = info.branches
            currentBranch = info.currentBranch
            files = []; commits = []; collapsed = []; viewed = []; expandedLarge = []; highlights = [:]
            history = []; commitsAfterBase = []; savedBranchSelection = nil
            errorMessage = nil
            addRecent(info.root.path)

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
            files = []; commits = []; mergeBase = nil
            refreshReviewForCurrentDiff()
            return
        }
        let (base, head, uncommitted) = (base, head, effectiveUncommitted)
        isLoading = true
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Git.compare(repo: repo, base: base, head: head, includeWorkingTree: uncommitted)
            }.value
            guard !Task.isCancelled else { return }
            files = result.files.sorted(by: Self.treeOrder)
            commits = result.commits
            mergeBase = result.mergeBase
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            files = []; commits = []; mergeBase = nil
            errorMessage = error.localizedDescription
        }
        refreshReviewForCurrentDiff()
        isLoading = false
    }

    /// Same order as the sidebar tree: folders before files at each level, then natural sort.
    static func treeOrder(_ a: FileDiff, _ b: FileDiff) -> Bool {
        let ac = a.path.split(separator: "/"), bc = b.path.split(separator: "/")
        for i in 0..<min(ac.count, bc.count) where ac[i] != bc[i] {
            let aIsDir = i < ac.count - 1, bIsDir = i < bc.count - 1
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
            if mode == .commits {  // new commits may exist
                history = await fetchHistory(commitBranch)
                if !base.isEmpty { commitsAfterBase = await fetchHistory("\(base)..\(commitBranch)") }
            }
            reloadToken += 1
        }
    }

    func swap() {
        guard mode == .branches else { return }  // in commits mode, base must come first
        (base, head) = (head, base)
    }

    // MARK: Refs and commit mode

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

    func setMode(_ newMode: CompareMode) async {
        guard newMode != mode else { return }
        if newMode == .commits {
            savedBranchSelection = (base, head)
            let branch = isBranch(head) ? head : (currentBranch ?? "HEAD")
            mode = .commits
            await selectCommitBranch(branch)
        } else {
            mode = .branches
            let saved = savedBranchSelection
            base = saved?.base ?? ""
            head = saved?.head ?? currentBranch ?? ""
            commitsAfterBase = []
        }
    }

    /// Commits mode: list another branch's history. Clears the selection.
    func selectCommitBranch(_ branch: String) async {
        commitBranch = branch
        base = ""; head = ""
        commitsAfterBase = []
        history = []
        history = await fetchHistory(branch)
    }

    /// Commits mode: choose the base commit. Compare defaults to the branch's latest
    /// commit unless the current compare commit is still after the new base.
    func selectBaseCommit(_ sha: String) async {
        let after = await fetchHistory("\(sha)..\(commitBranch)")
        let keepHead = after.contains { $0.sha == head }
        // Set everything together so only one diff load runs.
        commitsAfterBase = after
        base = sha
        if !keepHead { head = after.first?.sha ?? "" }
    }

    func selectCompareCommit(_ sha: String) { head = sha }

    private func fetchHistory(_ revision: String) async -> [Commit] {
        guard let repo else { return [] }
        return (try? await Task.detached { try Git.history(repo: repo, ref: revision) }.value) ?? []
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

    // MARK: Claude review

    enum ReviewStatus: Equatable {
        case idle
        case running(since: Date)
        case failed(String)
    }

    struct StoredReview: Codable {
        var review: Review
        var fingerprint: String
        var createdAt: Date
        var command: String
        var focus: String
        var costUSD: Double?
    }

    var isReviewing: Bool { if case .running = reviewStatus { true } else { false } }
    var reviewIsOutdated: Bool { storedReview.map { $0.fingerprint != diffFingerprint } ?? false }

    /// Identifies what was compared, so a review is saved and restored per comparison.
    private var reviewKey: String { "\(repo?.path ?? "")|\(base)|\(head)|\(effectiveUncommitted)" }

    func annotations(for file: FileDiff) -> [Annotation] { annotationsByFile[file.id] ?? [] }

    func fileID(for annotation: Annotation) -> String? { annotationFileIDs[annotation.id] }

    /// Make sure a file's rows are rendered before scrolling into it.
    func revealForJump(_ fileID: String) {
        collapsed.remove(fileID)
        expandedLarge.insert(fileID)
    }

    func flash(_ annotation: Annotation) {
        flashedAnnotationID = annotation.id
        let id = annotation.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if flashedAnnotationID == id { flashedAnnotationID = nil }
        }
    }

    func annotationLayout(for file: FileDiff) -> AnnotationLayout? { annotationLayouts[file.id] }

    func startReview(command rawCommand: String, focus: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo, !files.isEmpty, !command.isEmpty, reviewRun == nil else { return }
        rememberClaudeCommand(command)

        let context = ReviewContext(base: base, head: head, mergeBase: mergeBase,
                                    includesWorkingTree: effectiveUncommitted,
                                    commitCount: commits.count, focus: focus)
        let prompt = ReviewPrompt.build(files: files, context: context)
        let run = ClaudeReviewRun(command: command, directory: repo, prompt: prompt)
        let key = reviewKey, fingerprint = diffFingerprint
        reviewRun = run
        reviewTarget = "\(displayName(base))...\(displayName(head)) via \(command)"
        reviewStatus = .running(since: Date())

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try run.run() }.value
                let stored = StoredReview(review: result.review, fingerprint: fingerprint, createdAt: Date(),
                                          command: command, focus: focus, costUSD: result.costUSD)
                Self.saveReview(stored, key: key)
                guard reviewRun === run else { return }
                reviewRun = nil
                reviewStatus = .idle
                if reviewKey == key {  // still looking at the same comparison
                    storedReview = stored
                    reviewLoadedKey = key
                    rebuildAnnotationLayouts()
                }
            } catch {
                guard reviewRun === run else { return }
                reviewRun = nil
                reviewStatus = error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancelReview() {
        reviewRun?.cancel()
        reviewRun = nil
        reviewStatus = .idle
    }

    func dismissReviewError() {
        if case .failed = reviewStatus { reviewStatus = .idle }
    }

    func clearReview() {
        storedReview = nil
        Self.deleteReview(key: reviewKey)
        rebuildAnnotationLayouts()
    }

    private func rememberClaudeCommand(_ command: String) {
        recentClaudeCommands.removeAll { $0 == command }
        recentClaudeCommands.insert(command, at: 0)
        recentClaudeCommands = Array(recentClaudeCommands.prefix(6))
        UserDefaults.standard.set(recentClaudeCommands, forKey: "claudeCommands")
    }

    /// After every diff load: update the fingerprint and show the saved review for this comparison.
    private func refreshReviewForCurrentDiff() {
        diffFingerprint = Self.fingerprint(files)
        let key = reviewKey
        if reviewLoadedKey != key {
            reviewLoadedKey = key
            storedReview = (repo == nil || base.isEmpty || head.isEmpty) ? nil : Self.loadReview(key: key)
        }
        rebuildAnnotationLayouts()
    }

    private func rebuildAnnotationLayouts() {
        var byFile: [String: [Annotation]] = [:]
        var fileIDs: [String: String] = [:]
        for annotation in storedReview?.review.annotations ?? [] {
            guard let file = AnnotationFileResolver.resolve(annotation.file, in: files) else { continue }
            byFile[file.id, default: []].append(annotation)
            fileIDs[annotation.id] = file.id
        }
        var layouts: [String: AnnotationLayout] = [:]
        for file in files {
            if let annotations = byFile[file.id] {
                layouts[file.id] = AnnotationLayout(file: file, annotations: annotations)
            }
        }
        annotationsByFile = byFile
        annotationFileIDs = fileIDs
        annotationLayouts = layouts
    }

    private static func fingerprint(_ files: [FileDiff]) -> String {
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data("\u{1}\(file.path)\n".utf8))
            for line in file.hunks.flatMap(\.lines) {
                hasher.update(data: Data("\(line.kind)\(line.text)\n".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func reviewURL(key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appendingPathComponent("OptimusDiff/reviews", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    private static func loadReview(key: String) -> StoredReview? {
        guard let data = try? Data(contentsOf: reviewURL(key: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredReview.self, from: data)
    }

    private static func saveReview(_ review: StoredReview, key: String) {
        let url = reviewURL(key: key)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(review) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func deleteReview(key: String) {
        try? FileManager.default.removeItem(at: reviewURL(key: key))
    }
}
