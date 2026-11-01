import AppKit
import DiffCore
import SwiftUI

let mono = Font.system(size: 12, design: .monospaced)
/// Height of a code row when wrapping is off: one line of 12pt monospaced text plus padding.
let fixedRowHeight: CGFloat =
    ceil(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).boundingRectForFont.height) + 2

/// Stable, unique id for a diff row across all files (used for scrolling to it).
struct RowKey: Hashable {
    let fileID: String
    let index: Int
}

/// The row keys of one file without allocating an array: ForEach's own identity, instead of
/// an `.id()` modifier on each row (which makes SwiftUI resolve rows outside the viewport).
struct RowKeys: RandomAccessCollection {
    let fileID: String
    let count: Int
    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(i: Int) -> RowKey { RowKey(fileID: fileID, index: i) }
}

enum Palette {
    static let addBg = Color.green.opacity(0.14)
    static let addGutter = Color.green.opacity(0.24)
    static let delBg = Color.red.opacity(0.14)
    static let delGutter = Color.red.opacity(0.24)
    static let hunk = Color.blue.opacity(0.10)
    static let empty = Color.primary.opacity(0.04)
    static let border = Color(nsColor: .separatorColor)
    static let header = Color(nsColor: .windowBackgroundColor)
    static let code = Color(nsColor: .textBackgroundColor)
    static let selected = Color.accentColor.opacity(0.22)
    /// Word-level changes inside a changed line.
    static let addWord = Color.green.opacity(0.38)
    static let delWord = Color.red.opacity(0.38)
    static let match = Color.yellow.opacity(0.45)
    static let currentMatch = Color.orange.opacity(0.9)
}

// MARK: - Rows
//
// Performance notes (see VS Code / GitHub diff rendering):
// - Each row gets plain values (RowContent) and is Equatable, so SwiftUI skips rows whose
//   content didn't change instead of diffing a large view tree.
// - Few views per row: one Text for the gutter, one Text for marker + code, and
//   backgrounds instead of overlays.
// - No `.textSelection`: rows are selected by clicking and copied with ⇧⌘C / context menu.
// - With wrapping off every code row has the same height, so lazy-stack estimates (and
//   therefore scrolling and jumps) are exact.

/// Everything a diff row needs to render, as values.
struct RowContent: Equatable {
    struct Cell: Equatable {
        let line: DiffLine
        let number: Int?
        let highlighted: AttributedString?
        let marker: AnnotationKind?
    }

    enum Body: Equatable {
        case hunk(String, canExpand: Bool)
        case note(String)
        case unified(DiffLine, AttributedString?, AnnotationKind?)
        case split(Cell?, Cell?)
    }

    /// Per-file inputs for word emphasis, search highlights, context buttons and card state.
    struct Marks {
        let file: FileDiff
        let hits: [LineID: [Range<Int>]]?
        let currentMatch: SearchMatch?
        let canExpand: Bool
        let resolved: Set<String>
        let pending: Set<String>
    }

    let body: Body
    let cards: [Annotation]
    /// Only set when one of this row's cards is flashing, so other rows stay equal.
    let flashedID: String?
    let isSelected: Bool
    /// Of this row's cards: which are resolved / waiting for Claude.
    let resolvedIDs: Set<String>
    let pendingIDs: Set<String>

    static func make(
        _ row: DiffRow, highlight: HighlightedFile?, layout: AnnotationLayout?, marks: Marks,
        flashedID: String?, isSelected: Bool
    ) -> RowContent {
        var cards: [Annotation] = []
        let body: Body
        switch row {
        case .hunk(let header):
            body = .hunk(header, canExpand: marks.canExpand)
        case .line(let line):
            if line.kind == .noNewline {
                body = .note(line.text)
            } else {
                body = .unified(line, styled(line, highlight?.text(for: line), marks), layout?.marker(for: line))
                cards = layout?.cards(after: line) ?? []
            }
        case .pair(let old, let new):
            if let line = old ?? new, line.kind == .noNewline {
                body = .note(line.text)
            } else {
                let left = old.map {
                    Cell(
                        line: $0, number: $0.oldNumber,
                        highlighted: styled($0, highlight?.old[$0.oldNumber ?? -1], marks),
                        marker: layout?.markers[.old]?[$0.oldNumber ?? -1])
                }
                let right = new.map {
                    Cell(
                        line: $0, number: $0.newNumber,
                        highlighted: styled($0, highlight?.new[$0.newNumber ?? -1], marks),
                        marker: layout?.markers[.new]?[$0.newNumber ?? -1])
                }
                body = .split(left, right)
                var seen = Set<String>()
                cards = [old, new].compactMap { $0 }.flatMap { layout?.cards(after: $0) ?? [] }
                    .filter { seen.insert($0.id).inserted }
            }
        }
        let flash = flashedID.flatMap { id in cards.contains { $0.id == id } ? id : nil }
        let ids = Set(cards.map(\.id))
        return RowContent(
            body: body, cards: cards, flashedID: flash, isSelected: isSelected,
            resolvedIDs: cards.isEmpty ? [] : ids.intersection(marks.resolved),
            pendingIDs: cards.isEmpty ? [] : ids.intersection(marks.pending))
    }

    /// The line's text with word-level changes and search matches painted as backgrounds.
    /// Returns the plain highlight when there's nothing to paint (the common case).
    static func styled(_ line: DiffLine, _ base: AttributedString?, _ marks: Marks) -> AttributedString? {
        let word: [Range<Int>]? =
            switch line.kind {
            case .deletion: line.oldNumber.flatMap { marks.file.oldEmphasis[$0] }
            case .addition: line.newNumber.flatMap { marks.file.newEmphasis[$0] }
            default: nil
            }
        let hits = marks.hits?[line.id]
        guard word != nil || hits != nil else { return base }

        var text = base ?? AttributedString(line.displayText)
        let count = text.characters.count
        func paint(_ ranges: [Range<Int>], _ color: Color) {
            for r in ranges where !r.isEmpty && r.upperBound <= count {
                let lower = text.characters.index(text.startIndex, offsetBy: r.lowerBound)
                let upper = text.characters.index(lower, offsetBy: r.count)
                text[lower..<upper].backgroundColor = color
            }
        }
        if let word { paint(word, line.kind == .addition ? Palette.addWord : Palette.delWord) }
        if let hits { paint(hits, Palette.match) }
        if let current = marks.currentMatch, current.line == line.id { paint([current.range], Palette.currentMatch) }
        return text
    }
}

struct RowActions {
    let select: (_ extend: Bool) -> Void
    let copy: (_ asDiff: Bool) -> Void
    let copyReference: () -> Void
    let hasSelection: () -> Bool
    let ask: () -> Void
    let openInEditor: () -> Void
    let canOpenInEditor: Bool
    let expand: (_ full: Bool) -> Void
    let card: CardActions
}

struct DiffRowView: View, Equatable {
    let content: RowContent
    let digits: Int
    let wrap: Bool
    let actions: RowActions

    static func == (a: Self, b: Self) -> Bool {
        a.content == b.content && a.digits == b.digits && a.wrap == b.wrap
    }

    var body: some View {
        VStack(spacing: 0) {
            if wrap {
                line
            } else {
                // Fixed height: the lazy stack never has to measure the text.
                line.frame(
                    minWidth: 0, maxWidth: .infinity, minHeight: fixedRowHeight, maxHeight: fixedRowHeight,
                    alignment: .topLeading)
            }
            ForEach(content.cards) { card in
                AnnotationCard(
                    annotation: card, isFlashing: card.id == content.flashedID,
                    isResolved: content.resolvedIDs.contains(card.id),
                    isPending: content.pendingIDs.contains(card.id), actions: actions.card
                )
                .textSelection(.enabled)
            }
        }
        .cardSides()
    }

    @ViewBuilder
    private var line: some View {
        switch content.body {
        case .hunk(let header, let canExpand):
            HStack(spacing: 12) {
                Text(header)
                    .font(mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if canExpand {
                    Button {
                        actions.expand(false)
                    } label: {
                        Label("More context", systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    .help("Show 20 more unchanged lines around each change in this file")
                    Button("Full file") { actions.expand(true) }
                        .help("Show the whole file around the changes")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.vertical, 4).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.hunk)
        case .note(let text):
            Text(text)
                .font(mono.italic())
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(digits * 2 + 6) * 7.2).padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unified(let line, let highlighted, let marker):
            HStack(alignment: .top, spacing: 0) {
                gutter(
                    Self.pad(line.oldNumber, digits) + "  " + Self.pad(line.newNumber, digits),
                    kind: line.kind, marker: marker)
                code(line, highlighted)
            }
            .background(content.isSelected ? Palette.selected : line.kind.background)
            .interactive(actions)
        case .split(let left, let right):
            HStack(alignment: .top, spacing: 0) {
                splitCell(left)
                Palette.border.frame(width: 1)
                splitCell(right)
            }
            // Equal-height halves when wrapping; with fixed rows the frame above sets the height.
            .fixedSize(horizontal: false, vertical: wrap)
            .background(content.isSelected ? Palette.selected : .clear)
            .interactive(actions)
        }
    }

    @ViewBuilder
    private func splitCell(_ cell: RowContent.Cell?) -> some View {
        if let cell {
            HStack(alignment: .top, spacing: 0) {
                gutter(Self.pad(cell.number, digits), kind: cell.line.kind, marker: cell.marker)
                code(cell.line, cell.highlighted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(content.isSelected ? .clear : cell.line.kind.background)
        } else {
            Palette.empty.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Line numbers in one Text. A commented line gets its gutter tinted in the comment colour.
    private func gutter(_ numbers: String, kind: LineKind, marker: AnnotationKind?) -> some View {
        Text("  " + numbers + " ")
            .font(mono)
            .foregroundStyle(marker == nil ? Color.secondary : Color.primary)
            .padding(.vertical, 1)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(marker.map { $0.color.opacity(0.55) } ?? kind.gutterColor)
    }

    /// Marker and code in a single Text.
    private func code(_ line: DiffLine, _ highlighted: AttributedString?) -> some View {
        let marker = Text(line.kind.marker + " ").foregroundStyle(.secondary)
        let body: Text
        if let highlighted, !highlighted.characters.isEmpty {
            body = Text(highlighted)
        } else {
            body = Text(line.text.isEmpty ? " " : SyntaxHighlighter.displayText(line.text))
        }
        let text = Text("\(marker)\(body)").font(mono)
        return Group {
            if wrap {
                text
            } else {
                text.lineLimit(1)
            }
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func pad(_ number: Int?, _ width: Int) -> String {
        let s = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }
}

extension View {
    /// Click to select (shift-click extends); right-click to copy.
    fileprivate func interactive(_ actions: RowActions) -> some View {
        contentShape(Rectangle())
            .onTapGesture { actions.select(NSEvent.modifierFlags.contains(.shift)) }
            .contextMenu {
                Button(actions.hasSelection() ? "Copy Selected Lines" : "Copy Line") { actions.copy(false) }
                Button("Copy as Diff") { actions.copy(true) }
                Button("Copy Reference (path:line)") { actions.copyReference() }
                Divider()
                Button(actions.hasSelection() ? "Ask Claude About Selected Lines…" : "Ask Claude About This Line…") {
                    actions.ask()
                }
                Button("Open in Editor") { actions.openInEditor() }
                    .disabled(!actions.canOpenInEditor)
            }
    }
}

extension LineKind {
    fileprivate var marker: String {
        switch self {
        case .addition: "+"
        case .deletion: "-"
        default: " "
        }
    }

    fileprivate var background: Color {
        switch self {
        case .addition: Palette.addBg
        case .deletion: Palette.delBg
        default: .clear
        }
    }

    fileprivate var gutterColor: Color {
        switch self {
        case .addition: Palette.addGutter
        case .deletion: Palette.delGutter
        default: .clear
        }
    }
}

extension View {
    /// Left/right borders so consecutive rows read as one card per file. Backgrounds rather
    /// than overlays: cheaper per row.
    func cardSides() -> some View {
        background(Palette.code)
            .padding(.horizontal, 1)
            .background(Palette.border)
    }
}
