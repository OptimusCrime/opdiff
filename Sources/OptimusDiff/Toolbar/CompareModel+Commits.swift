import DiffCore
import SwiftUI

extension CompareModel {
    // MARK: Switching modes and commits range

    /// `commit` is what to show in single commit mode; the default is the selection carried over
    /// from commits mode, or else the branch's latest commit.
    func setMode(_ newMode: CompareMode, showing commit: Commit? = nil) async {
        guard newMode != mode else { return }
        let previous = mode
        if previous == .branches {
            savedBranchSelection = (base, head)
            commitBranch = isBranch(head) ? head : (currentBranch ?? "HEAD")
        }
        mode = newMode
        switch newMode {
        case .branches:
            let saved = savedBranchSelection
            base = saved?.base ?? ""
            head = saved?.head ?? currentBranch ?? ""
            commitsAfterBase = []
        case .commits:
            // Coming from a single commit, keep showing it as the range parent...commit.
            if previous == .commit, history.contains(where: { $0.sha == base }) {
                await selectBaseCommit(base)
            } else {
                await selectCommitBranch(commitBranch)
            }
        case .commit:
            commitsAfterBase = []
            if previous == .commits, let target = commit ?? self.commit(for: head) ?? history.first {
                await selectSingleCommit(target)
            } else {
                await selectCommitBranch(commitBranch, showing: commit)
            }
        }
    }

    /// Commits and single commit mode: list another branch's history. Clears the selection;
    /// single commit mode then shows `commit`, by default the branch's latest.
    func selectCommitBranch(_ branch: String, showing commit: Commit? = nil) async {
        commitBranch = branch
        base = ""
        head = ""
        commitsAfterBase = []
        history = []
        history = await fetchHistory(branch)
        if mode == .commit, let target = commit ?? history.first { await selectSingleCommit(target) }
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

    func fetchHistory(_ revision: String) async -> [Commit] {
        guard let repo else { return [] }
        return (try? await Task.detached { try Git.history(repo: repo, ref: revision) }.value) ?? []
    }

    /// The last `count` commits of the current branch: one commit in single commit mode, more
    /// as a range in commits mode.
    func showRecentCommits(_ count: Int) async {
        guard let repo else { return }
        head = currentBranch ?? "HEAD"
        guard count > 1 else {
            await setMode(.commit)
            return
        }
        await setMode(.commits)
        let branch = commitBranch
        let oldest = try? await Task.detached { try Git.commitBehind(repo: repo, ref: branch, count: count) }.value
        if let oldest, !oldest.isEmpty, oldest != history.first?.sha {
            await selectBaseCommit(oldest)
        } else {  // only one commit exists
            await setMode(.commit)
        }
    }

    // MARK: Single commit

    private var shownCommitIndex: Int? {
        mode == .commit ? history.firstIndex { $0.sha == head } : nil
    }

    /// The commit before the shown one in the branch's history, in single commit mode.
    var olderCommit: Commit? {
        guard let i = shownCommitIndex, i + 1 < history.count else { return nil }
        return history[i + 1]
    }

    /// The commit after the shown one in the branch's history, in single commit mode.
    var newerCommit: Commit? {
        guard let i = shownCommitIndex, i > 0 else { return nil }
        return history[i - 1]
    }

    func showOlderCommit() async { if let commit = olderCommit { await selectSingleCommit(commit) } }
    func showNewerCommit() async { if let commit = newerCommit { await selectSingleCommit(commit) } }

    /// Single commit mode: show `commit`, compared with its first parent.
    func selectSingleCommit(_ commit: Commit) async {
        var parent = commit.parents.first
        if parent == nil, let repo {
            parent = try? await Task.detached { try Git.emptyTree(repo: repo) }.value
        }
        guard let parent else { return }
        // Set both together so only one diff load runs.
        (base, head) = (parent, commit.sha)
    }

    /// Jump to `commit` from any mode, e.g. from the commit list.
    func showSingleCommit(_ commit: Commit) async {
        if mode == .commit {
            await selectSingleCommit(commit)
        } else {
            await setMode(.commit, showing: commit)
        }
    }
}
