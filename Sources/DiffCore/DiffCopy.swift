import Foundation

/// Text for copying diff rows to the clipboard.
public enum DiffCopy {
    /// Code of the rows; with `asDiff`, unified-diff lines with +/-/space markers and hunk headers.
    public static func text<Rows: Sequence>(_ rows: Rows, asDiff: Bool) -> String where Rows.Element == DiffRow {
        var out: [String] = []
        for row in rows {
            switch row {
            case .hunk(let header):
                if asDiff { out.append(header) }
            case .line(let line):
                out.append(asDiff ? diffLine(line) : line.text)
            case .pair(let old, let new):
                if asDiff {
                    if let old, let new, old == new {
                        out.append(diffLine(old))
                    } else {
                        if let old { out.append(diffLine(old)) }
                        if let new { out.append(diffLine(new)) }
                    }
                } else if let line = new ?? old {
                    out.append(line.text)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// "path:12" / "path:12-20" using new-file line numbers (old ones if only deleted lines).
    public static func reference<Rows: Sequence>(_ rows: Rows, in file: FileDiff) -> String
    where Rows.Element == DiffRow {
        var newNumbers: [Int] = []
        var oldNumbers: [Int] = []
        for row in rows {
            switch row {
            case .hunk: break
            case .line(let line):
                if let n = line.newNumber {
                    newNumbers.append(n)
                } else if let n = line.oldNumber {
                    oldNumbers.append(n)
                }
            case .pair(let old, let new):
                if let n = new?.newNumber {
                    newNumbers.append(n)
                } else if let n = old?.oldNumber {
                    oldNumbers.append(n)
                }
            }
        }
        let numbers = newNumbers.isEmpty ? oldNumbers : newNumbers
        let path = newNumbers.isEmpty ? (file.oldPath ?? file.path) : file.path
        guard let first = numbers.min(), let last = numbers.max() else { return path }
        return first == last ? "\(path):\(first)" : "\(path):\(first)-\(last)"
    }

    static func diffLine(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+" + line.text
        case .deletion: "-" + line.text
        case .context: " " + line.text
        case .noNewline: line.text
        }
    }
}
