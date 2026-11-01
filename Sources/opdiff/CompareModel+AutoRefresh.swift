import DiffCore
import SwiftUI

extension CompareModel {
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
