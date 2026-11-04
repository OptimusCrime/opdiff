import CryptoKit
import DiffCore
import Foundation

extension CompareModel {
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
    var reviewKey: String {
        "\(repo?.path ?? "")|\(base)|\(head)|\(effectiveUncommitted)\(onlyUncommitted ? "|only" : "")"
    }

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
        let context = ReviewContext(
            base: base, head: head, mergeBase: mergeBase,
            includesWorkingTree: effectiveUncommitted,
            commitCount: commits.count, focus: focus, uncommittedOnly: onlyUncommitted,
            singleCommit: mode == .commit)
        return ReviewPrompt.build(files: files, context: context)
    }

    /// `customPrompt` replaces the generated prompt (edited in the preview sheet).
    func startReview(command rawCommand: String, focus: String, customPrompt: String? = nil) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo, !files.isEmpty, !command.isEmpty, reviewRun == nil else { return }
        rememberClaudeCommand(command)

        let prompt = customPrompt ?? reviewPrompt(focus: focus)
        let run = ClaudeReviewRun(command: command, directory: repo, prompt: prompt)
        let key = reviewKey
        let fingerprint = diffFingerprint
        reviewRun = run
        reviewTarget = "\(comparisonTitle) via \(command)"
        reviewStatus = .running(since: Date())

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try run.run() }.value
                let stored = StoredReview(
                    review: result.review, fingerprint: fingerprint, createdAt: Date(),
                    command: command, focus: focus, costUSD: result.costUSD)
                ReviewStore.saveReview(stored, key: key)
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
        ReviewStore.deleteReview(key: reviewKey)
        rebuildAnnotationLayouts()
    }

    func rememberClaudeCommand(_ command: String) {
        recentClaudeCommands.removeAll { $0 == command }
        recentClaudeCommands.insert(command, at: 0)
        recentClaudeCommands = Array(recentClaudeCommands.prefix(6))
        UserDefaults.standard.set(recentClaudeCommands, forKey: "claudeCommands")
    }

    /// After every diff load: update the fingerprint and show the saved review for this comparison.
    func refreshReviewForCurrentDiff() {
        diffFingerprint = Self.fingerprint(files)
        let key = reviewKey
        let hasComparison = repo != nil && !base.isEmpty && !head.isEmpty
        if reviewLoadedKey != key {
            reviewLoadedKey = key
            storedReview = hasComparison ? ReviewStore.loadReview(key: key) : nil
        }
        if questionsLoadedKey != key {
            questionsLoadedKey = key
            questions = hasComparison ? ReviewStore.loadQuestions(key: key) : []
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
        ReviewStore.saveReview(review, key: reviewKey)
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
                hasher.update(
                    data: Data("\(line.kind)\(line.oldNumber ?? 0):\(line.newNumber ?? 0)\(line.text)\n".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
