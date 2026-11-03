import DiffCore
import SwiftUI

extension CompareModel {
    nonisolated static let fullContext = 1_000_000

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
        let from = onlyUncommitted ? "HEAD" : mergeBase ?? base
        let to: String? = effectiveUncommitted ? nil : head
        let (algorithm, ws, path, oldPath) = (diffAlgorithm, ignoreWhitespace, file.path, file.oldPath)
        let result = try? await Task.detached(priority: .userInitiated) {
            try Git.fileDiff(
                repo: repo, from: from, to: to, path: path, oldPath: oldPath, context: context,
                algorithm: algorithm, ignoreWhitespace: ws)
        }.value
        guard let updated = result ?? nil, let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index] = updated
        if lineSelection?.fileID == id { lineSelection = nil }
        if navPosition?.fileID == id { navPosition = NavPosition(fileID: id, index: -1) }
    }
}
