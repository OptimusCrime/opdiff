import Foundation

public enum LineKind: Sendable, Hashable {
    case context, addition, deletion, noNewline
}

public struct DiffLine: Sendable, Hashable {
    public let kind: LineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
}

public struct Hunk: Sendable {
    public let header: String
    public var lines: [DiffLine]
}

public enum FileStatus: String, Sendable {
    case added = "A", deleted = "D", modified = "M", renamed = "R", copied = "C"
}

/// A pre-computed display row, so the UI never has to do work while scrolling.
public enum DiffRow: Sendable {
    case hunk(String)
    case line(DiffLine)
    /// Side-by-side row: (old side, new side). Either side may be empty.
    case pair(DiffLine?, DiffLine?)
}

public struct FileDiff: Identifiable, Sendable {
    public var id: String { path }
    public let oldPath: String?
    public let newPath: String?
    public let status: FileStatus
    public let isBinary: Bool
    public let hunks: [Hunk]
    public let additions: Int
    public let deletions: Int
    /// Changes when the file's diff changes; used to reset the "Viewed" checkbox.
    public let contentHash: Int
    public let maxLineNumber: Int
    public let unifiedRows: [DiffRow]
    public let splitRows: [DiffRow]

    public var path: String { newPath ?? oldPath ?? "" }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

public struct Commit: Identifiable, Sendable, Hashable {
    public let hash: String
    public let subject: String
    public let author: String
    public let date: String
    public var id: String { hash }
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
