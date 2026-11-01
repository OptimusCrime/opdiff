import Foundation

public struct Commit: Identifiable, Sendable, Hashable {
    /// Full commit hash.
    public let sha: String
    /// Abbreviated hash for display.
    public let hash: String
    public let subject: String
    public let author: String
    public let date: String
    public var id: String { sha }
}

public struct Comparison: Sendable {
    public let files: [FileDiff]
    public let commits: [Commit]
    public let mergeBase: String?
}

public struct RepositoryInfo: Sendable {
    public let root: URL
    /// Local branches first, then remote branches; each group sorted by most recent commit.
    public let branches: [String]
    public let currentBranch: String?
    public let defaultBase: String?
}
