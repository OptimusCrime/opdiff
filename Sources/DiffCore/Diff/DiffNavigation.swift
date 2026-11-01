import Foundation

/// Finding rows for keyboard navigation.
public enum DiffNavigation {
    /// Runs of consecutive changed rows (added/deleted lines), as row index ranges.
    public static func changeBlocks(_ rows: [DiffRow]) -> [ClosedRange<Int>] {
        var blocks: [ClosedRange<Int>] = []
        var start: Int?
        for (i, row) in rows.enumerated() {
            if isChange(row) {
                if start == nil { start = i }
            } else if let s = start {
                blocks.append(s...(i - 1))
                start = nil
            }
        }
        if let s = start { blocks.append(s...(rows.count - 1)) }
        return blocks
    }

    public static func isChange(_ row: DiffRow) -> Bool {
        switch row {
        case .hunk: false
        case .line(let line): line.kind == .addition || line.kind == .deletion
        case .pair(let old, let new): old?.kind == .deletion || new?.kind == .addition
        }
    }

    /// The row showing a line (either side of a split row).
    public static func rowIndex(of id: LineID, in rows: [DiffRow]) -> Int? {
        rows.firstIndex { row in
            switch row {
            case .hunk: false
            case .line(let line): line.id == id
            case .pair(let old, let new): old?.id == id || new?.id == id
            }
        }
    }

    /// The new-file line number to open in an editor for a row: the row's own new line, or for
    /// a deleted line the next (else previous) line that exists in the new file.
    public static func editorLine(at index: Int, in rows: [DiffRow]) -> Int? {
        func newNumber(_ row: DiffRow) -> Int? {
            switch row {
            case .hunk: nil
            case .line(let line): line.kind == .deletion ? nil : line.newNumber
            case .pair(_, let new): new?.newNumber
            }
        }
        guard rows.indices.contains(index) else { return nil }
        for i in index..<rows.count {
            if case .hunk = rows[i], i != index { break }
            if let n = newNumber(rows[i]) { return n }
        }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let n = newNumber(rows[i]) { return n }
        }
        return nil
    }
}
