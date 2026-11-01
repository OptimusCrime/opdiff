import AppKit
import DiffCore
import SwiftUI

extension CompareModel {
    // MARK: Line selection and copying

    struct LineSelection: Equatable {
        let fileID: String
        let split: Bool
        var anchor: Int
        var range: ClosedRange<Int>
    }

    func isRowSelected(fileID: String, index: Int, split: Bool) -> Bool {
        guard let s = lineSelection, s.fileID == fileID, s.split == split else { return false }
        return s.range.contains(index)
    }

    /// Click selects one row; shift-click extends from the anchor (like GitHub/VS Code).
    func selectRow(fileID: String, index: Int, split: Bool, extend: Bool) {
        navPosition = NavPosition(fileID: fileID, index: index)
        if extend, var s = lineSelection, s.fileID == fileID, s.split == split {
            s.range = min(s.anchor, index)...max(s.anchor, index)
            lineSelection = s
        } else if let s = lineSelection, s.fileID == fileID, s.split == split, s.range == index...index {
            lineSelection = nil  // clicking the only selected row again deselects it
        } else {
            lineSelection = LineSelection(fileID: fileID, split: split, anchor: index, range: index...index)
        }
    }

    var hasLineSelection: Bool { lineSelection != nil }

    /// Copies the selected rows, or `fallback` (the right-clicked row) if it isn't part of the selection.
    func copyLines(asDiff: Bool, fallback: (fileID: String, index: Int, split: Bool)? = nil) {
        guard let (_, rows) = rowsToCopy(fallback: fallback) else { return }
        Pasteboard.copy(DiffCopy.text(rows, asDiff: asDiff))
    }

    func copyReference(fallback: (fileID: String, index: Int, split: Bool)? = nil) {
        guard let (file, rows) = rowsToCopy(fallback: fallback) else { return }
        Pasteboard.copy(DiffCopy.reference(rows, in: file))
    }

    func rowsToCopy(fallback: (fileID: String, index: Int, split: Bool)?) -> (FileDiff, ArraySlice<DiffRow>)? {
        var target = lineSelection
        if let fallback, !isRowSelected(fileID: fallback.fileID, index: fallback.index, split: fallback.split) {
            target = LineSelection(
                fileID: fallback.fileID, split: fallback.split, anchor: fallback.index,
                range: fallback.index...fallback.index)
        }
        guard let target, let file = files.first(where: { $0.id == target.fileID }) else { return nil }
        let rows = rows(of: file, split: target.split)
        let range = target.range.clamped(to: 0...(max(rows.count - 1, 0)))
        guard !rows.isEmpty else { return nil }
        return (file, rows[range])
    }
}
