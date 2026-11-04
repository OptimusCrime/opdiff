import Foundation

/// Which changes are shown when `compare` is the checked-out branch.
enum ChangeScope: String, CaseIterable, Hashable {
    /// Committed changes plus staged, unstaged and untracked work (the default).
    case all
    /// Only what is committed on `compare`.
    case committed
    /// Only the work since the last commit (the working tree compared with HEAD).
    case uncommitted

    var label: String {
        switch self {
        case .all: "Committed + uncommitted"
        case .committed: "Committed only"
        case .uncommitted: "Uncommitted only"
        }
    }

    var help: String {
        switch self {
        case .all: "Changes on compare since it diverged from base, plus staged, unstaged and untracked work"
        case .committed: "Only the commits on compare since it diverged from base"
        case .uncommitted: "Only staged, unstaged and untracked work since the last commit (base is ignored)"
        }
    }
}

extension CompareModel {
    /// Working-tree changes only belong to the checked-out branch.
    var canIncludeUncommitted: Bool { !head.isEmpty && head == currentBranch }
    /// Falls back to committed changes when the working tree doesn't apply (e.g. compare is a commit).
    var effectiveScope: ChangeScope { canIncludeUncommitted ? changeScope : .committed }
    /// The diff includes the working tree (with or without the branch's commits).
    var effectiveUncommitted: Bool { effectiveScope != .committed }
    /// The diff is only the working tree compared with HEAD; base is ignored.
    var onlyUncommitted: Bool { effectiveScope == .uncommitted }

    /// "base...compare", "compare (uncommitted)", or the commit in single commit mode.
    var comparisonTitle: String {
        guard !base.isEmpty, !head.isEmpty else { return "" }
        if onlyUncommitted { return "\(displayName(head)) (uncommitted)" }
        if mode == .commit { return displayName(head) }
        return "\(displayName(base))...\(displayName(head))"
    }
}
