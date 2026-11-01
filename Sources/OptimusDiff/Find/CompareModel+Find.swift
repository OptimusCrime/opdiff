import AppKit
import DiffCore
import SwiftUI

extension CompareModel {
    nonisolated static let searchLimit = 5000

    // MARK: Find

    func showFind() {
        findVisible = true
        findFocusToken += 1
    }

    func closeFind() {
        findVisible = false
        searchQuery = ""
    }

    var currentMatch: SearchMatch? {
        currentMatchIndex.flatMap { searchMatches.indices.contains($0) ? searchMatches[$0] : nil }
    }

    /// Re-run the search (after typing, or after the diff changed). `jump` moves to the first
    /// match at or after the current place, like a browser's find bar.
    func scheduleSearch(jump: Bool) {
        searchTask?.cancel()
        let query = searchQuery
        let files = files
        guard !query.isEmpty else {
            searchMatches = []
            searchHits = [:]
            currentMatchIndex = nil
            return
        }
        searchTask = Task {
            if jump { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                DiffSearch.find(query, in: files, limit: CompareModel.searchLimit)
            }.value
            guard !Task.isCancelled, query == searchQuery else { return }
            applySearch(matches, jump: jump)
        }
    }

    private func applySearch(_ matches: [SearchMatch], jump: Bool) {
        let previous = currentMatch
        searchMatches = matches
        var hits: [String: [LineID: [Range<Int>]]] = [:]
        for m in matches { hits[m.fileID, default: [:]][m.line, default: []].append(m.range) }
        searchHits = hits
        if jump {
            let startFile = cursor?.file ?? 0
            let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.id, $0) })
            currentMatchIndex =
                matches.isEmpty
                ? nil
                : matches.firstIndex { (order[$0.fileID] ?? 0) >= startFile } ?? 0
            if let i = currentMatchIndex { showMatch(i) }
        } else {
            currentMatchIndex = previous.flatMap { matches.firstIndex(of: $0) }
        }
    }

    func findNext(forward: Bool) {
        if !findVisible { showFind() }
        guard !searchMatches.isEmpty else {
            if !searchQuery.isEmpty { NSSound.beep() }
            return
        }
        let n = searchMatches.count
        let i = currentMatchIndex.map { (($0 + (forward ? 1 : -1)) % n + n) % n } ?? (forward ? 0 : n - 1)
        currentMatchIndex = i
        showMatch(i)
    }

    private func showMatch(_ i: Int) {
        let match = searchMatches[i]
        guard let file = file(id: match.fileID) else { return }
        let row = DiffNavigation.rowIndex(of: match.line, in: rows(of: file))
        lineSelection = nil
        navPosition = NavPosition(fileID: match.fileID, index: row ?? -1)
        requestJump(fileID: match.fileID, row: row)
    }
}
