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

extension DiffLine {
    /// Identifies a line within one file: deletions have only an old number, additions only a new one.
    public var id: LineID { LineID(old: kind == .addition ? nil : oldNumber, new: kind == .deletion ? nil : newNumber) }

    /// The text as shown on screen (tabs expanded). Search and word-diff ranges are offsets into this.
    public var displayText: String { DiffLine.displayText(text) }

    public static func displayText(_ text: String) -> String {
        text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
    }
}

public struct LineID: Hashable, Sendable {
    public let old: Int?
    public let new: Int?
    public init(old: Int?, new: Int?) {
        self.old = old
        self.new = new
    }
}

public struct Hunk: Sendable {
    public let header: String
    public var lines: [DiffLine]
}

public enum FileStatus: String, Sendable {
    case added = "A"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case copied = "C"
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
    /// Changes when any shown line changes (including context); keys highlighting caches.
    public let contentHash: Int
    /// Changes only when the added/deleted lines change; used for "Viewed" and review freshness,
    /// so showing more context doesn't count as a change.
    public let changeHash: Int
    public let maxLineNumber: Int
    public let unifiedRows: [DiffRow]
    public let splitRows: [DiffRow]
    /// Word-level changes inside paired deleted/added lines: character ranges in `displayText`,
    /// keyed by old line number (deletions) and new line number (additions).
    public let oldEmphasis: [Int: [Range<Int>]]
    public let newEmphasis: [Int: [Range<Int>]]

    public var path: String { newPath ?? oldPath ?? "" }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}
