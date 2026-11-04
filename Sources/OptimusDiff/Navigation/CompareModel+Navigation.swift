import AppKit
import DiffCore
import SwiftUI

/// A row (or, with index -1, a file header) that keyboard navigation continues from.
struct NavPosition: Equatable {
    let fileID: String
    let index: Int
}

/// Asks the diff view to scroll to a file, or to a row in it. The token makes repeated
/// requests for the same place count as new.
struct JumpRequest: Equatable {
    let fileID: String
    let row: Int?
    let token = UUID()
}

extension CompareModel {
    func rows(of file: FileDiff, split: Bool? = nil) -> [DiffRow] {
        (split ?? splitView) ? file.splitRows : file.unifiedRows
    }

    func file(id: String) -> FileDiff? { files.first { $0.id == id } }

    func fileIndex(_ id: String) -> Int? { files.firstIndex { $0.id == id } }

    // MARK: Scrolling

    func requestJump(fileID: String, row: Int?) {
        revealForJump(fileID)
        jumpRequest = JumpRequest(fileID: fileID, row: row)
    }

    /// Scroll to a comment's card and flash it.
    func jump(to annotation: Annotation) {
        guard let fileID = fileID(for: annotation), let file = file(id: fileID) else { return }
        let row = annotationLayout(for: file)?.rowIndex(of: annotation, in: rows(of: file))
        lineSelection = nil
        navPosition = NavPosition(fileID: fileID, index: row ?? -1)
        lastCommentID = annotation.id
        flash(annotation)
        requestJump(fileID: fileID, row: row)
    }

    /// The sidebar showed a file: keyboard navigation continues from there.
    func noteFileShown(_ fileID: String) {
        lineSelection = nil
        navPosition = NavPosition(fileID: fileID, index: -1)
    }

    // MARK: Keyboard navigation

    /// The current place: the selected lines, else the last navigation target.
    var cursor: (file: Int, lower: Int, upper: Int)? {
        if let s = lineSelection, s.split == splitView, let i = fileIndex(s.fileID) {
            return (i, s.range.lowerBound, s.range.upperBound)
        }
        if let p = navPosition, let i = fileIndex(p.fileID) { return (i, p.index, p.index) }
        return nil
    }

    var currentFile: FileDiff? { cursor.map { files[$0.file] } ?? files.first }

    /// Select the next (or previous) run of changed lines, skipping files marked as viewed.
    func goToChange(forward: Bool) {
        guard !files.isEmpty else { return }
        let start = cursor
        let order: [Int] =
            forward
            ? Array((start?.file ?? 0)..<files.count)
            : Array((0...(start?.file ?? files.count - 1)).reversed())
        for i in order {
            let file = files[i]
            if isViewed(file), i != start?.file { continue }
            let blocks = DiffNavigation.changeBlocks(rows(of: file))
            let block: ClosedRange<Int>?
            if let start, i == start.file {
                block =
                    forward
                    ? blocks.first { $0.lowerBound > start.upper }
                    : blocks.last { $0.upperBound < start.lower }
            } else {
                block = forward ? blocks.first : blocks.last
            }
            if let block {
                lineSelection = LineSelection(fileID: file.id, split: splitView, anchor: block.lowerBound, range: block)
                navPosition = NavPosition(fileID: file.id, index: block.lowerBound)
                requestJump(fileID: file.id, row: block.lowerBound)
                return
            }
        }
        NSSound.beep()
    }

    /// Jump to the next (or previous) unresolved comment or question.
    func goToComment(forward: Bool) {
        var targets: [(file: Int, row: Int, annotation: Annotation)] = []
        for (i, file) in files.enumerated() {
            guard let layout = annotationLayout(for: file) else { continue }
            let rows = rows(of: file)
            for a in annotations(for: file) where !isResolved(a) {
                targets.append((i, layout.rowIndex(of: a, in: rows) ?? -1, a))
            }
        }
        targets.sort { ($0.file, $0.row) < ($1.file, $1.row) }
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }

        var next: Int?
        if let c = cursor {
            // Several comments on one row: step through them in order.
            if let id = lastCommentID, let current = targets.firstIndex(where: { $0.annotation.id == id }),
                targets[current].file == c.file, targets[current].row == c.lower
            {
                let candidate = current + (forward ? 1 : -1)
                next = targets.indices.contains(candidate) ? candidate : nil
            } else {
                next =
                    forward
                    ? targets.firstIndex { ($0.file, $0.row) > (c.file, c.upper) }
                    : targets.lastIndex { ($0.file, $0.row) < (c.file, c.lower) }
            }
        } else {
            next = forward ? 0 : targets.count - 1
        }
        guard let next else {
            NSSound.beep()
            return
        }
        jump(to: targets[next].annotation)
    }

    /// Toggle "Viewed" on the current file; when marking it viewed, move on to the next unviewed file.
    func toggleViewedAndAdvance() {
        guard let file = currentFile, let i = fileIndex(file.id) else { return }
        let nowViewed = !isViewed(file)
        setViewed(file, nowViewed)
        guard nowViewed else { return }
        lineSelection = nil
        let next = files[(i + 1)...].first { !isViewed($0) } ?? files[..<i].first { !isViewed($0) }
        let target = next ?? file
        navPosition = NavPosition(fileID: target.id, index: -1)
        jumpRequest = JumpRequest(fileID: target.id, row: nil)
        if next != nil { revealForJump(target.id) }
    }

    /// Single-key shortcuts in the diff window. Ignored while typing or with ⌘/⌃/⌥ held.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === mainWindow, window.attachedSheet == nil,
            !(window.firstResponder is NSText),
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        // Stepping works on empty commits too, so this comes before the check for files.
        if mode == .commit, key == "h" || key == "l" {
            Task { await key == "h" ? showOlderCommit() : showNewerCommit() }
            return true
        }
        guard !files.isEmpty else { return false }
        switch key {
        case "j": goToChange(forward: true)
        case "k": goToChange(forward: false)
        case "n": goToComment(forward: true)
        case "p": goToComment(forward: false)
        case "v": toggleViewedAndAdvance()
        case "o": openCurrentInEditor()
        case "a": beginQuestion()
        default: return false
        }
        return true
    }

    // MARK: Open in editor

    func openInEditor(fileID: String, index: Int?) {
        guard let file = file(id: fileID), file.status != .deleted, let url = fileURL(file) else {
            NSSound.beep()
            return
        }
        let line = index.flatMap { DiffNavigation.editorLine(at: $0, in: rows(of: file)) } ?? firstChangedLine(file)
        EditorOpener.open(url, line: line)
    }

    func openCurrentInEditor() {
        guard let c = cursor else {
            if let first = files.first { openInEditor(fileID: first.id, index: nil) }
            return
        }
        openInEditor(fileID: files[c.file].id, index: c.lower >= 0 ? c.lower : nil)
    }

    private func firstChangedLine(_ file: FileDiff) -> Int? {
        let lines = file.hunks.flatMap(\.lines)
        return lines.first { $0.kind == .addition }?.newNumber ?? lines.first { $0.kind != .deletion }?.newNumber
    }
}
