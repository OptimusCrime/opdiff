import Foundation

/// One occurrence of the search text in a diff line.
public struct SearchMatch: Hashable, Sendable {
    public let fileID: String
    public let line: LineID
    /// Character range in the line's `displayText`.
    public let range: Range<Int>
}

public enum DiffSearch {
    /// Case-insensitive matches in every shown line, in file and line order.
    /// Stops after `limit` matches; check `matches.count == limit` to tell the user.
    public static func find(_ query: String, in files: [FileDiff], limit: Int = 5000) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        for file in files {
            for hunk in file.hunks {
                for line in hunk.lines where line.kind != .noNewline {
                    let text = line.displayText
                    var from = text.startIndex
                    while from < text.endIndex,
                        let r = text.range(
                            of: query, options: [.caseInsensitive, .diacriticInsensitive],
                            range: from..<text.endIndex)
                    {
                        let start = text.distance(from: text.startIndex, to: r.lowerBound)
                        let length = text.distance(from: r.lowerBound, to: r.upperBound)
                        matches.append(SearchMatch(fileID: file.id, line: line.id, range: start..<(start + length)))
                        if matches.count >= limit { return matches }
                        from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
                    }
                }
            }
        }
        return matches
    }
}
