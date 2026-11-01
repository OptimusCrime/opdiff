import AppKit
import CoreServices
import DiffCore
import SwiftUI

/// A row (or, with index -1, a file header) that keyboard navigation continues from.
struct NavPosition: Equatable {
    let fileID: String
    let index: Int
}

/// Asks the diff view to scroll to a file, or to a row in it. The token makes repeated
/// requests for the same place count as new.
struct JumpRequest: Equatable {
    let fileID: String
    let row: Int?
    let token = UUID()
}

/// Lines the user is about to ask Claude about.
struct QuestionDraft: Identifiable {
    let id = UUID()
    let fileID: String
    let range: ClosedRange<Int>
    let split: Bool
    /// e.g. "src/app.swift:12-20"
    let reference: String
    /// The lines as a diff, shown in the sheet.
    let preview: String
}

extension CompareModel {
    nonisolated static let fullContext = 1_000_000
    nonisolated static let searchLimit = 5000

    func rows(of file: FileDiff, split: Bool? = nil) -> [DiffRow] {
        (split ?? splitView) ? file.splitRows : file.unifiedRows
    }

    func file(id: String) -> FileDiff? { files.first { $0.id == id } }

    private func fileIndex(_ id: String) -> Int? { files.firstIndex { $0.id == id } }

    // MARK: Scrolling

    func requestJump(fileID: String, row: Int?) {
        revealForJump(fileID)
        jumpRequest = JumpRequest(fileID: fileID, row: row)
    }

    /// Scroll to a comment's card and flash it.
    func jump(to annotation: Annotation) {
        guard let fileID = fileID(for: annotation), let file = file(id: fileID) else { return }
        let row = annotationLayout(for: file)?.rowIndex(of: annotation, in: rows(of: file))
        lineSelection = nil
        navPosition = NavPosition(fileID: fileID, index: row ?? -1)
        lastCommentID = annotation.id
        flash(annotation)
        requestJump(fileID: fileID, row: row)
    }

    /// The sidebar showed a file: keyboard navigation continues from there.
    func noteFileShown(_ fileID: String) {
        lineSelection = nil
        navPosition = NavPosition(fileID: fileID, index: -1)
    }

    // MARK: Keyboard navigation

    /// The current place: the selected lines, else the last navigation target.
    private var cursor: (file: Int, lower: Int, upper: Int)? {
        if let s = lineSelection, s.split == splitView, let i = fileIndex(s.fileID) {
            return (i, s.range.lowerBound, s.range.upperBound)
        }
        if let p = navPosition, let i = fileIndex(p.fileID) { return (i, p.index, p.index) }
        return nil
    }

    var currentFile: FileDiff? { cursor.map { files[$0.file] } ?? files.first }

    /// Select the next (or previous) run of changed lines, skipping files marked as viewed.
    func goToChange(forward: Bool) {
        guard !files.isEmpty else { return }
        let start = cursor
        let order: [Int] = forward
            ? Array((start?.file ?? 0)..<files.count)
            : Array((0...(start?.file ?? files.count - 1)).reversed())
        for i in order {
            let file = files[i]
            if isViewed(file), i != start?.file { continue }
            let blocks = DiffNavigation.changeBlocks(rows(of: file))
            let block: ClosedRange<Int>?
            if let start, i == start.file {
                block = forward ? blocks.first { $0.lowerBound > start.upper }
                                : blocks.last { $0.upperBound < start.lower }
            } else {
                block = forward ? blocks.first : blocks.last
            }
            if let block {
                lineSelection = LineSelection(fileID: file.id, split: splitView, anchor: block.lowerBound, range: block)
                navPosition = NavPosition(fileID: file.id, index: block.lowerBound)
                requestJump(fileID: file.id, row: block.lowerBound)
                return
            }
        }
        NSSound.beep()
    }

    /// Jump to the next (or previous) unresolved comment or question.
    func goToComment(forward: Bool) {
        var targets: [(file: Int, row: Int, annotation: Annotation)] = []
        for (i, file) in files.enumerated() {
            guard let layout = annotationLayout(for: file) else { continue }
            let rows = rows(of: file)
            for a in annotations(for: file) where !isResolved(a) {
                targets.append((i, layout.rowIndex(of: a, in: rows) ?? -1, a))
            }
        }
        targets.sort { ($0.file, $0.row) < ($1.file, $1.row) }
        guard !targets.isEmpty else { NSSound.beep(); return }

        var next: Int?
        if let c = cursor {
            // Several comments on one row: step through them in order.
            if let id = lastCommentID, let current = targets.firstIndex(where: { $0.annotation.id == id }),
               targets[current].file == c.file, targets[current].row == c.lower {
                let candidate = current + (forward ? 1 : -1)
                next = targets.indices.contains(candidate) ? candidate : nil
            } else {
                next = forward ? targets.firstIndex { ($0.file, $0.row) > (c.file, c.upper) }
                               : targets.lastIndex { ($0.file, $0.row) < (c.file, c.lower) }
            }
        } else {
            next = forward ? 0 : targets.count - 1
        }
        guard let next else { NSSound.beep(); return }
        jump(to: targets[next].annotation)
    }

    /// Toggle "Viewed" on the current file; when marking it viewed, move on to the next unviewed file.
    func toggleViewedAndAdvance() {
        guard let file = currentFile, let i = fileIndex(file.id) else { return }
        let nowViewed = !isViewed(file)
        setViewed(file, nowViewed)
        guard nowViewed else { return }
        lineSelection = nil
        let next = files[(i + 1)...].first { !isViewed($0) } ?? files[..<i].first { !isViewed($0) }
        let target = next ?? file
        navPosition = NavPosition(fileID: target.id, index: -1)
        jumpRequest = JumpRequest(fileID: target.id, row: nil)
        if next != nil { revealForJump(target.id) }
    }

    /// Single-key shortcuts in the diff window. Ignored while typing or with ⌘/⌃/⌥ held.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === mainWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !files.isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "j": goToChange(forward: true)
        case "k": goToChange(forward: false)
        case "n": goToComment(forward: true)
        case "p": goToComment(forward: false)
        case "v": toggleViewedAndAdvance()
        case "o": openCurrentInEditor()
        case "a": beginQuestion()
        default: return false
        }
        return true
    }

    // MARK: Find

    func showFind() {
        findVisible = true
        findFocusToken += 1
    }

    func closeFind() {
        findVisible = false
        searchQuery = ""
    }

    var currentMatch: SearchMatch? {
        currentMatchIndex.flatMap { searchMatches.indices.contains($0) ? searchMatches[$0] : nil }
    }

    /// Re-run the search (after typing, or after the diff changed). `jump` moves to the first
    /// match at or after the current place, like a browser's find bar.
    func scheduleSearch(jump: Bool) {
        searchTask?.cancel()
        let query = searchQuery, files = files
        guard !query.isEmpty else {
            searchMatches = []; searchHits = [:]; currentMatchIndex = nil
            return
        }
        searchTask = Task {
            if jump { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                DiffSearch.find(query, in: files, limit: CompareModel.searchLimit)
            }.value
            guard !Task.isCancelled, query == searchQuery else { return }
            applySearch(matches, jump: jump)
        }
    }

    private func applySearch(_ matches: [SearchMatch], jump: Bool) {
        let previous = currentMatch
        searchMatches = matches
        var hits: [String: [LineID: [Range<Int>]]] = [:]
        for m in matches { hits[m.fileID, default: [:]][m.line, default: []].append(m.range) }
        searchHits = hits
        if jump {
            let startFile = cursor?.file ?? 0
            let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.id, $0) })
            currentMatchIndex = matches.isEmpty ? nil
                : matches.firstIndex { (order[$0.fileID] ?? 0) >= startFile } ?? 0
            if let i = currentMatchIndex { showMatch(i) }
        } else {
            currentMatchIndex = previous.flatMap { matches.firstIndex(of: $0) }
        }
    }

    func findNext(forward: Bool) {
        if !findVisible { showFind() }
        guard !searchMatches.isEmpty else { if !searchQuery.isEmpty { NSSound.beep() }; return }
        let n = searchMatches.count
        let i = currentMatchIndex.map { (($0 + (forward ? 1 : -1)) % n + n) % n } ?? (forward ? 0 : n - 1)
        currentMatchIndex = i
        showMatch(i)
    }

    private func showMatch(_ i: Int) {
        let match = searchMatches[i]
        guard let file = file(id: match.fileID) else { return }
        let row = DiffNavigation.rowIndex(of: match.line, in: rows(of: file))
        lineSelection = nil
        navPosition = NavPosition(fileID: match.fileID, index: row ?? -1)
        requestJump(fileID: match.fileID, row: row)
    }

    // MARK: More context

    func canExpandContext(_ file: FileDiff) -> Bool {
        [.modified, .renamed, .copied].contains(file.status) && !file.isBinary
            && (contextLines[file.id] ?? 3) < Self.fullContext
    }

    /// Show 20 more lines around every change in the file, or the whole file.
    func expandContext(_ file: FileDiff, full: Bool) {
        let current = contextLines[file.id] ?? 3
        contextLines[file.id] = full ? Self.fullContext : current + 20
        expandedLarge.insert(file.id)  // a long file shown in full must not hide behind "Load diff"
        Task {
            await reloadWithContext(file.id)
            rebuildAnnotationLayouts()
            scheduleSearch(jump: false)
        }
    }

    /// After a diff load: forget expansions from another comparison, re-apply the rest.
    func reapplyContext() async {
        if contextScope != reviewKey {
            contextScope = reviewKey
            contextLines = [:]
            return
        }
        for id in contextLines.keys where file(id: id) != nil {
            await reloadWithContext(id)
        }
    }

    private func reloadWithContext(_ id: String) async {
        guard let repo, let file = file(id: id), let context = contextLines[id] else { return }
        let from = mergeBase ?? base
        let to: String? = effectiveUncommitted ? nil : head
        let (algorithm, ws, path, oldPath) = (diffAlgorithm, ignoreWhitespace, file.path, file.oldPath)
        let result = try? await Task.detached(priority: .userInitiated) {
            try Git.fileDiff(repo: repo, from: from, to: to, path: path, oldPath: oldPath, context: context,
                             algorithm: algorithm, ignoreWhitespace: ws)
        }.value
        guard let updated = result ?? nil, let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index] = updated
        if lineSelection?.fileID == id { lineSelection = nil }
        if navPosition?.fileID == id { navPosition = NavPosition(fileID: id, index: -1) }
    }

    // MARK: Open in editor

    func openInEditor(fileID: String, index: Int?) {
        guard let file = file(id: fileID), file.status != .deleted, let url = fileURL(file) else {
            NSSound.beep(); return
        }
        let line = index.flatMap { DiffNavigation.editorLine(at: $0, in: rows(of: file)) } ?? firstChangedLine(file)
        EditorOpener.open(url, line: line)
    }

    func openCurrentInEditor() {
        guard let c = cursor else {
            if let first = files.first { openInEditor(fileID: first.id, index: nil) }
            return
        }
        openInEditor(fileID: files[c.file].id, index: c.lower >= 0 ? c.lower : nil)
    }

    private func firstChangedLine(_ file: FileDiff) -> Int? {
        let lines = file.hunks.flatMap(\.lines)
        return lines.first { $0.kind == .addition }?.newNumber ?? lines.first { $0.kind != .deletion }?.newNumber
    }

    // MARK: Questions about lines

    /// Opens the question sheet for the selected lines (or the right-clicked row).
    func beginQuestion(fallback: (fileID: String, index: Int, split: Bool)? = nil) {
        guard let (file, rows) = rowsToCopy(fallback: fallback), !rows.isEmpty else { NSSound.beep(); return }
        questionDraft = QuestionDraft(fileID: file.id, range: rows.startIndex...(rows.endIndex - 1), split: splitView,
                                      reference: DiffCopy.reference(rows, in: file),
                                      preview: DiffCopy.text(rows, asDiff: true))
    }

    func askQuestion(_ draft: QuestionDraft, question rawQuestion: String, command rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo, !command.isEmpty, !question.isEmpty, let file = file(id: draft.fileID) else { return }
        let rows = rows(of: file, split: draft.split)
        guard draft.range.upperBound < rows.count else { return }

        var lines: [DiffLine] = []
        for row in rows[draft.range] {
            switch row {
            case .hunk: break
            case .line(let line): lines.append(line)
            case .pair(let old, let new):
                if let old, let new, old == new { lines.append(old) } else { lines += [old, new].compactMap { $0 } }
            }
        }
        let newNumbers = lines.filter { $0.kind != .deletion }.compactMap(\.newNumber)
        let oldNumbers = lines.compactMap(\.oldNumber)
        let (side, numbers): (AnnotationSide, [Int]) = newNumbers.isEmpty ? (.old, oldNumbers) : (.new, newNumbers)
        guard let low = numbers.min(), let high = numbers.max() else { return }

        rememberClaudeCommand(command)
        let uid = UUID().uuidString
        let key = reviewKey
        questions.append(Annotation(file: file.path, side: side, startLine: low, endLine: high, kind: .question,
                                    comment: "", question: question, uid: uid))
        pendingQuestionIDs.insert(uid)
        Self.saveQuestions(questions, key: key)
        rebuildAnnotationLayouts()

        let context = ReviewContext(base: base, head: head, mergeBase: mergeBase,
                                    includesWorkingTree: effectiveUncommitted, commitCount: commits.count, focus: "")
        let prompt = QuestionPrompt.build(file: file, selected: lines, question: question, context: context)
        let run = ClaudeReviewRun(command: command, directory: repo, prompt: prompt, schema: AnswerSchema.json)
        questionRuns[uid] = run
        Task {
            var answer: String?
            do {
                answer = try await Task.detached(priority: .userInitiated) { try run.runAnswer() }.value.answer
            } catch is CancellationError {
                answer = nil
            } catch {
                answer = "⚠️ Couldn't get an answer: \(error.localizedDescription)"
            }
            finishQuestion(uid: uid, key: key, answer: answer)
        }
    }

    /// Store the answer (nil: cancelled, so drop the question).
    private func finishQuestion(uid: String, key: String, answer: String?) {
        questionRuns[uid] = nil
        pendingQuestionIDs.remove(uid)
        let isCurrent = key == reviewKey
        var list = isCurrent ? questions : Self.loadQuestions(key: key)
        if let answer, let i = list.firstIndex(where: { $0.uid == uid }) {
            list[i].comment = answer
        } else {
            list.removeAll { $0.uid == uid }
        }
        Self.saveQuestions(list, key: key)
        if isCurrent {
            questions = list
            rebuildAnnotationLayouts()
        }
    }

    func isPending(_ annotation: Annotation) -> Bool {
        annotation.uid.map(pendingQuestionIDs.contains) ?? false
    }

    func cancelQuestion(_ annotation: Annotation) {
        guard let uid = annotation.uid else { return }
        questionRuns[uid]?.cancel()
    }

    func removeQuestion(_ annotation: Annotation) {
        guard let uid = annotation.uid else { return }
        questionRuns[uid]?.cancel()
        questions.removeAll { $0.uid == uid }
        Self.saveQuestions(questions, key: reviewKey)
        rebuildAnnotationLayouts()
    }

    // MARK: Auto-refresh

    func updateWatcher() {
        watcher = nil
        guard autoRefresh, let repo else { return }
        watcher = RepoWatcher(path: repo.path) { [weak self] paths in
            Task { @MainActor in self?.filesChanged(paths) }
        }
    }

    private func filesChanged(_ paths: [String]) {
        changedPaths.formUnion(paths)
        watchDebounce?.cancel()
        watchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let paths = changedPaths
            changedPaths = []
            if await changesMatter(paths) { refresh() }
        }
    }

    /// Branch/commit changes always matter; working-tree changes only when uncommitted
    /// changes are shown and the file isn't ignored by git.
    private func changesMatter(_ paths: Set<String>) async -> Bool {
        guard let repo else { return false }
        let roots = Set([repo.path, repo.resolvingSymlinksInPath().path]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var work: [String] = []
        for path in paths {
            guard let root = roots.first(where: path.hasPrefix) else { continue }
            let relative = String(path.dropFirst(root.count))
            if relative == ".git" || relative.hasPrefix(".git/") {
                if relative == ".git/HEAD" || relative == ".git/packed-refs" || relative.hasPrefix(".git/refs/") {
                    return true
                }
                continue
            }
            work.append(relative)
        }
        guard effectiveUncommitted, !work.isEmpty else { return false }
        let candidates = work
        let ignored = await Task.detached { Git.ignoredPaths(candidates, in: repo) }.value
        return candidates.contains { !ignored.contains($0) }
    }
}

/// FSEvents on the repository folder (file-level events), delivered on a background queue.
final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
