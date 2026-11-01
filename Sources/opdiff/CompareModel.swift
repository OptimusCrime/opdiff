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
    /// What the running review is about, e.g. "main...feature via claude".
    private(set) var reviewTarget: String?
    private var reviewRun: ClaudeReviewRun?
    private var reviewLoadedKey: String?

    /// Passed per git command; the user's global git config is left alone.
    var diffAlgorithm: DiffAlgorithm = DiffAlgorithm(rawValue: UserDefaults.standard.string(forKey: "diffAlgorithm") ?? "") ?? .myers {
        didSet { UserDefaults.standard.set(diffAlgorithm.rawValue, forKey: "diffAlgorithm") }
    }

    /// Lines selected by clicking (shift-click extends), for copying.
    var lineSelection: LineSelection?

    // MARK: View options (persisted)

    var splitView = UserDefaults.standard.bool(forKey: "splitView") {
        didSet { UserDefaults.standard.set(splitView, forKey: "splitView"); lineSelection = nil }
    }
    /// git diff -w.
    var ignoreWhitespace = UserDefaults.standard.bool(forKey: "ignoreWhitespace") {
        didSet { UserDefaults.standard.set(ignoreWhitespace, forKey: "ignoreWhitespace") }
    }
    /// Reload when files in the repository change.
    var autoRefresh = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh"); updateWatcher() }
    }
    /// Leave resolved review comments out of the diff and the comment list.
    var hideResolved = UserDefaults.standard.bool(forKey: "hideResolved") {
        didSet { UserDefaults.standard.set(hideResolved, forKey: "hideResolved"); rebuildAnnotationLayouts() }
    }

    // MARK: Feature state (see CompareModel+Features.swift)

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

    var canIncludeUncommitted: Bool { !head.isEmpty && head == currentBranch }
    var effectiveUncommitted: Bool { includeUncommitted && canIncludeUncommitted }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// The view re-runs `loadDiff()` whenever this changes.
    var compareKey: String {
        "\(repo?.path ?? "")|\(base)|\(head)|\(effectiveUncommitted)|\(diffAlgorithm.rawValue)|\(ignoreWhitespace)|\(reloadToken)"
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
            files = []; commits = []; mergeBase = nil
            refreshReviewForCurrentDiff()
            return
        }
        let (base, head, uncommitted, algorithm, ws) = (base, head, effectiveUncommitted, diffAlgorithm, ignoreWhitespace)
        isLoading = true
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Git.compare(repo: repo, base: base, head: head, includeWorkingTree: uncommitted,
                                algorithm: algorithm, ignoreWhitespace: ws)
            }.value
            guard !Task.isCancelled else { return }
            files = result.files.sorted(by: Self.treeOrder)
            commits = result.commits
            mergeBase = result.mergeBase
            errorMessage = nil
            // Keep the selection across refreshes while it still points at existing rows.
            if let s = lineSelection,
               !(files.first { $0.id == s.fileID }.map { s.range.upperBound < rows(of: $0, split: s.split).count } ?? false) {
                lineSelection = nil
            }
            await reapplyContext()
        } catch {
            guard !Task.isCancelled else { return }
            files = []; commits = []; mergeBase = nil
            errorMessage = error.localizedDescription
        }
        refreshReviewForCurrentDiff()
        scheduleSearch(jump: false)
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

    /// Only the changed lines count: showing more context keeps a file viewed.
    private func viewedKey(_ f: FileDiff) -> String { "\(f.path)#\(f.changeHash)" }

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
        /// Ids of comments the user marked as resolved.
        var resolved: Set<String>? = nil
    }

    var isReviewing: Bool { if case .running = reviewStatus { true } else { false } }
    var reviewIsOutdated: Bool { storedReview.map { $0.fingerprint != diffFingerprint } ?? false }

    /// Identifies what was compared, so a review is saved and restored per comparison.
    var reviewKey: String { "\(repo?.path ?? "")|\(base)|\(head)|\(effectiveUncommitted)" }

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

    /// The prompt Claude gets for the current diff (what "Preview Prompt" shows).
    func reviewPrompt(focus: String) -> String {
        let context = ReviewContext(base: base, head: head, mergeBase: mergeBase,
                                    includesWorkingTree: effectiveUncommitted,
                                    commitCount: commits.count, focus: focus)
        return ReviewPrompt.build(files: files, context: context)
    }

    /// `customPrompt` replaces the generated prompt (edited in the preview sheet).
    func startReview(command rawCommand: String, focus: String, customPrompt: String? = nil) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo, !files.isEmpty, !command.isEmpty, reviewRun == nil else { return }
        rememberClaudeCommand(command)

        let prompt = customPrompt ?? reviewPrompt(focus: focus)
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

    func rememberClaudeCommand(_ command: String) {
        recentClaudeCommands.removeAll { $0 == command }
        recentClaudeCommands.insert(command, at: 0)
        recentClaudeCommands = Array(recentClaudeCommands.prefix(6))
        UserDefaults.standard.set(recentClaudeCommands, forKey: "claudeCommands")
    }

    /// After every diff load: update the fingerprint and show the saved review for this comparison.
    private func refreshReviewForCurrentDiff() {
        diffFingerprint = Self.fingerprint(files)
        let key = reviewKey
        let hasComparison = repo != nil && !base.isEmpty && !head.isEmpty
        if reviewLoadedKey != key {
            reviewLoadedKey = key
            storedReview = hasComparison ? Self.loadReview(key: key) : nil
        }
        if questionsLoadedKey != key {
            questionsLoadedKey = key
            questions = hasComparison ? Self.loadQuestions(key: key) : []
        }
        rebuildAnnotationLayouts()
    }

    func isResolved(_ annotation: Annotation) -> Bool {
        storedReview?.resolved?.contains(annotation.id) ?? false
    }

    var resolvedCount: Int {
        guard let review = storedReview else { return 0 }
        return review.review.annotations.filter(isResolved).count
    }

    func toggleResolved(_ annotation: Annotation) {
        guard var review = storedReview, annotation.kind != .question else { return }
        var resolved = review.resolved ?? []
        if resolved.remove(annotation.id) == nil { resolved.insert(annotation.id) }
        review.resolved = resolved
        storedReview = review
        Self.saveReview(review, key: reviewKey)
        rebuildAnnotationLayouts()
    }

    /// Review comments (minus hidden resolved ones) plus the user's questions.
    var visibleAnnotations: [Annotation] {
        let review = (storedReview?.review.annotations ?? []).filter { !(hideResolved && isResolved($0)) }
        return review + questions
    }

    func rebuildAnnotationLayouts() {
        var byFile: [String: [Annotation]] = [:]
        var fileIDs: [String: String] = [:]
        for annotation in visibleAnnotations {
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
            // Changed lines only, so showing more context doesn't make a review look outdated.
            for line in file.hunks.flatMap(\.lines) where line.kind == .addition || line.kind == .deletion {
                hasher.update(data: Data("\(line.kind)\(line.oldNumber ?? 0):\(line.newNumber ?? 0)\(line.text)\n".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func reviewURL(key: String, folder: String = "reviews") -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appendingPathComponent("OptimusDiff/\(folder)", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    static func loadQuestions(key: String) -> [Annotation] {
        guard let data = try? Data(contentsOf: reviewURL(key: key, folder: "questions")) else { return [] }
        return (try? JSONDecoder().decode([Annotation].self, from: data)) ?? []
    }

    static func saveQuestions(_ questions: [Annotation], key: String) {
        let url = reviewURL(key: key, folder: "questions")
        if questions.isEmpty { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(questions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func loadReview(key: String) -> StoredReview? {
        guard let data = try? Data(contentsOf: reviewURL(key: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredReview.self, from: data)
    }

    static func saveReview(_ review: StoredReview, key: String) {
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

    // MARK: Line selection and copying

    struct LineSelection: Equatable {
        let fileID: String
        let split: Bool
        var anchor: Int
        var range: ClosedRange<Int>
    }

    func isRowSelected(fileID: String, index: Int, split: Bool) -> Bool {
        guard let s = lineSelection, s.fileID == fileID, s.split == split else { return false }
        return s.range.contains(index)
    }

    /// Click selects one row; shift-click extends from the anchor (like GitHub/VS Code).
    func selectRow(fileID: String, index: Int, split: Bool, extend: Bool) {
        navPosition = NavPosition(fileID: fileID, index: index)
        if extend, var s = lineSelection, s.fileID == fileID, s.split == split {
            s.range = min(s.anchor, index)...max(s.anchor, index)
            lineSelection = s
        } else if let s = lineSelection, s.fileID == fileID, s.split == split, s.range == index...index {
            lineSelection = nil  // clicking the only selected row again deselects it
        } else {
            lineSelection = LineSelection(fileID: fileID, split: split, anchor: index, range: index...index)
        }
    }

    func clearLineSelection() { lineSelection = nil }

    var hasLineSelection: Bool { lineSelection != nil }

    /// Copies the selected rows, or `fallback` (the right-clicked row) if it isn't part of the selection.
    func copyLines(asDiff: Bool, fallback: (fileID: String, index: Int, split: Bool)? = nil) {
        guard let (_, rows) = rowsToCopy(fallback: fallback) else { return }
        Self.copyToPasteboard(DiffCopy.text(rows, asDiff: asDiff))
    }

    func copyReference(fallback: (fileID: String, index: Int, split: Bool)? = nil) {
        guard let (file, rows) = rowsToCopy(fallback: fallback) else { return }
        Self.copyToPasteboard(DiffCopy.reference(rows, in: file))
    }

    func rowsToCopy(fallback: (fileID: String, index: Int, split: Bool)?) -> (FileDiff, ArraySlice<DiffRow>)? {
        var target = lineSelection
        if let fallback, !isRowSelected(fileID: fallback.fileID, index: fallback.index, split: fallback.split) {
            target = LineSelection(fileID: fallback.fileID, split: fallback.split, anchor: fallback.index,
                                   range: fallback.index...fallback.index)
        }
        guard let target, let file = files.first(where: { $0.id == target.fileID }) else { return nil }
        let rows = rows(of: file, split: target.split)
        let range = target.range.clamped(to: 0...(max(rows.count - 1, 0)))
        guard !rows.isEmpty else { return nil }
        return (file, rows[range])
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
