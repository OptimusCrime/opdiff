import AppKit
import DiffCore
import SwiftUI

private let mono = Font.system(size: 12, design: .monospaced)
/// Height of a code row when wrapping is off: one line of 12pt monospaced text plus padding.
private let fixedRowHeight: CGFloat = ceil(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).boundingRectForFont.height) + 2

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

private enum Palette {
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
}

/// All files in one long scroll, like GitHub's "Files changed" tab.
struct DiffListView: View {
    let model: CompareModel
    @Binding var selection: String?
    let splitView: Bool
    let wrapLines: Bool
    let jumpRequest: JumpRequest?
    let onOpenReview: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    SummaryHeader(model: model, onOpenReview: onOpenReview)
                        .padding(.bottom, 16)
                    ForEach(model.files) { file in
                        Section {
                            fileBody(file)
                        } header: {
                            FileHeader(file: file, model: model)
                                .id(file.id)
                                // Highlight lazily: the header appears when the file scrolls into view.
                                .task(id: highlightTaskID(file)) {
                                    guard !model.isCollapsed(file), !model.isLargeHidden(file) else { return }
                                    await model.ensureHighlighted(file, dark: colorScheme == .dark)
                                }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .task(id: colorScheme) { await SyntaxHighlighter.shared.warmUp(dark: colorScheme == .dark) }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: jumpRequest) { _, request in
                if let request { jump(to: request.annotation, proxy: proxy) }
            }
            .onChange(of: splitView) { model.clearLineSelection() }
        }
    }

    /// Scroll to the row that holds an annotation's card.
    ///
    /// The diff is a LazyVStack, so rows far away haven't been laid out and their heights
    /// are estimates: a single scrollTo can land off target. Scroll to the file first, then
    /// to the row, and once more after layout has settled.
    private func jump(to annotation: Annotation, proxy: ScrollViewProxy) {
        guard let fileID = model.fileID(for: annotation),
              let file = model.files.first(where: { $0.id == fileID }) else { return }
        model.revealForJump(fileID)
        let rows = splitView ? file.splitRows : file.unifiedRows
        let rowID = model.annotationLayout(for: file)?.rowIndex(of: annotation, in: rows).map { RowKey(fileID: fileID, index: $0) }
        // Below the sticky file header rather than underneath it.
        let anchor = UnitPoint(x: 0, y: 0.25)
        proxy.scrollTo(fileID, anchor: .top)
        model.flash(annotation)
        guard let rowID else { return }  // comment not on a changed line: the file header is the target
        Task { @MainActor in
            for delay in [80, 220, 400] {
                try? await Task.sleep(for: .milliseconds(delay))
                proxy.scrollTo(rowID, anchor: anchor)
            }
        }
    }

    private func rowActions(fileID: String, index: Int) -> RowActions {
        let split = splitView
        let target = (fileID: fileID, index: index, split: split)
        return RowActions(
            select: { extend in model.selectRow(fileID: fileID, index: index, split: split, extend: extend) },
            copy: { asDiff in model.copyLines(asDiff: asDiff, fallback: target) },
            copyReference: { model.copyReference(fallback: target) },
            hasSelection: { model.hasLineSelection })
    }

    private func highlightTaskID(_ file: FileDiff) -> String {
        "\(file.id)#\(file.contentHash)#\(colorScheme == .dark)#\(model.isCollapsed(file))#\(model.isLargeHidden(file))"
    }

    @ViewBuilder
    private func fileBody(_ file: FileDiff) -> some View {
        if !model.isCollapsed(file) {
            if file.isBinary {
                NoteRow(text: "Binary file not shown.")
            } else if file.hunks.isEmpty {
                NoteRow(text: file.status == .renamed ? "File renamed without changes." : "No content changes.")
            } else if model.isLargeHidden(file) {
                NoteRow(text: "Large diff (\(file.lineCount) lines) is hidden.", action: ("Load diff", { model.expandLarge(file) }))
            } else {
                let rows = splitView ? file.splitRows : file.unifiedRows
                let digits = max(String(file.maxLineNumber).count, 2)
                let highlight = model.highlighted(file, dark: colorScheme == .dark)
                let layout = model.annotationLayout(for: file)
                let flashed = model.flashedAnnotationID
                ForEach(layout?.unplaced ?? []) { annotation in
                    AnnotationCard(annotation: annotation, note: "not on a changed line",
                                   isFlashing: annotation.id == flashed)
                        .cardSides()
                }
                ForEach(RowKeys(fileID: file.id, count: rows.count), id: \.self) { key in
                    let i = key.index
                    let content = RowContent.make(rows[i], highlight: highlight, layout: layout, flashedID: flashed,
                                                  isSelected: model.isRowSelected(fileID: file.id, index: i, split: splitView))
                    DiffRowView(content: content, digits: digits, wrap: wrapLines,
                                actions: rowActions(fileID: file.id, index: i))
                        .equatable()
                }
            }
        }
        Rectangle().fill(Palette.border).frame(height: 1).padding(.bottom, 16)
    }
}

private struct SummaryHeader: View {
    let model: CompareModel
    let onOpenReview: () -> Void
    @State private var showCommits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Comparing changes").font(.title2.bold())
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            if !model.base.isEmpty, !model.head.isEmpty {
                let base = Text(model.displayName(model.base)).bold()
                let head = Text(model.displayName(model.head)).bold()
                let extra = model.effectiveUncommitted ? ", including uncommitted work" : ""
                if model.mode == .branches {
                    Text("Changes on \(head) since it diverged from \(base)\(extra).")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Changes from \(base) to \(head)\(extra).")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Button { showCommits.toggle() } label: {
                    Label("\(model.commits.count) commit\(model.commits.count == 1 ? "" : "s")", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.link)
                .disabled(model.commits.isEmpty)
                .popover(isPresented: $showCommits) { CommitList(commits: model.commits) }

                Label("\(model.files.count) file\(model.files.count == 1 ? "" : "s") changed", systemImage: "doc.on.doc")
                DiffStat(additions: model.totalAdditions, deletions: model.totalDeletions)
                    .monospacedDigit()
                if let mb = model.mergeBase {
                    Text("merge base \(String(mb.prefix(8)))").font(.callout.monospaced()).foregroundStyle(.tertiary)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.files.isEmpty, !model.isLoading {
                Text(model.branches.isEmpty
                     ? "This repository has no commits yet — commit something first, then compare branches."
                     : model.mode == .commits && model.base.isEmpty
                     ? "Select a base commit, then the commit to compare it with."
                     : model.mode == .commits && model.head.isEmpty
                     ? "There are no commits after the base commit on \(model.commitBranch)."
                     : model.base.isEmpty || model.head.isEmpty
                     ? "Select a base and a compare branch."
                     : model.base == model.head && !model.effectiveUncommitted
                     ? "Choose different branches to compare."
                     : "There isn't anything to compare — the branches are identical.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            ReviewPanel(model: model, onOpenReview: onOpenReview)
                .padding(.top, 4)
        }
        .textSelection(.disabled)
    }
}

private struct CommitList: View {
    let commits: [Commit]

    var body: some View {
        List(commits) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text(c.subject).lineLimit(2)
                HStack(spacing: 6) {
                    Text(c.hash).font(.caption.monospaced())
                    Text("\(c.author) · \(c.date)").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .frame(width: 480, height: 360)
    }
}

private struct FileHeader: View {
    let file: FileDiff
    let model: CompareModel

    var body: some View {
        let collapsed = model.isCollapsed(file)
        HStack(spacing: 8) {
            Button { model.toggleCollapsed(file) } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            StatusBadge(status: file.status)
            if file.status == .renamed || file.status == .copied, let old = file.oldPath {
                Text(old).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            }
            Text(file.path).fontWeight(.semibold)
            DiffStat(additions: file.additions, deletions: file.deletions)
                .font(.caption.monospacedDigit())
            let annotations = model.annotations(for: file)
            if let strongest = annotations.map(\.kind).max() {
                AnnotationBadge(count: annotations.count, kind: strongest)
            }
            Spacer()
            Toggle("Viewed", isOn: Binding(get: { model.isViewed(file) }, set: { model.setViewed(file, $0) }))
                .toggleStyle(.checkbox)
            Menu {
                Button("Open File") { if let url = model.fileURL(file) { NSWorkspace.shared.open(url) } }
                    .disabled(file.status == .deleted)
                Button("Reveal in Finder") {
                    if let url = model.fileURL(file) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(file.status == .deleted)
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.header)
        .overlay(Rectangle().strokeBorder(Palette.border, lineWidth: 1))
        .textSelection(.disabled)
    }
}

private struct NoteRow: View {
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            if let action { Button(action.0, action: action.1).buttonStyle(.link) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .cardSides()
    }
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
        case hunk(String)
        case note(String)
        case unified(DiffLine, AttributedString?, AnnotationKind?)
        case split(Cell?, Cell?)
    }

    let body: Body
    let cards: [Annotation]
    /// Only set when one of this row's cards is flashing, so other rows stay equal.
    let flashedID: String?
    let isSelected: Bool

    static func make(_ row: DiffRow, highlight: HighlightedFile?, layout: AnnotationLayout?,
                     flashedID: String?, isSelected: Bool) -> RowContent {
        var cards: [Annotation] = []
        let body: Body
        switch row {
        case .hunk(let header):
            body = .hunk(header)
        case .line(let line):
            if line.kind == .noNewline {
                body = .note(line.text)
            } else {
                body = .unified(line, highlight?.text(for: line), layout?.marker(for: line))
                cards = layout?.cards(after: line) ?? []
            }
        case .pair(let old, let new):
            if let line = old ?? new, line.kind == .noNewline {
                body = .note(line.text)
            } else {
                let left = old.map { Cell(line: $0, number: $0.oldNumber,
                                          highlighted: highlight?.old[$0.oldNumber ?? -1],
                                          marker: layout?.markers[.old]?[$0.oldNumber ?? -1]) }
                let right = new.map { Cell(line: $0, number: $0.newNumber,
                                           highlighted: highlight?.new[$0.newNumber ?? -1],
                                           marker: layout?.markers[.new]?[$0.newNumber ?? -1]) }
                body = .split(left, right)
                var seen = Set<String>()
                cards = [old, new].compactMap { $0 }.flatMap { layout?.cards(after: $0) ?? [] }
                    .filter { seen.insert($0.id).inserted }
            }
        }
        let flash = flashedID.flatMap { id in cards.contains { $0.id == id } ? id : nil }
        return RowContent(body: body, cards: cards, flashedID: flash, isSelected: isSelected)
    }
}

struct RowActions {
    let select: (_ extend: Bool) -> Void
    let copy: (_ asDiff: Bool) -> Void
    let copyReference: () -> Void
    let hasSelection: () -> Bool
}

private struct DiffRowView: View, Equatable {
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
                line.frame(minWidth: 0, maxWidth: .infinity, minHeight: fixedRowHeight, maxHeight: fixedRowHeight,
                           alignment: .topLeading)
            }
            ForEach(content.cards) { card in
                AnnotationCard(annotation: card, isFlashing: card.id == content.flashedID)
                    .textSelection(.enabled)
            }
        }
        .cardSides()
    }

    @ViewBuilder
    private var line: some View {
        switch content.body {
        case .hunk(let header):
            Text(header)
                .font(mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                gutter(Self.pad(line.oldNumber, digits) + "  " + Self.pad(line.newNumber, digits),
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

private extension View {
    /// Click to select (shift-click extends); right-click to copy.
    func interactive(_ actions: RowActions) -> some View {
        contentShape(Rectangle())
            .onTapGesture { actions.select(NSEvent.modifierFlags.contains(.shift)) }
            .contextMenu {
                Button(actions.hasSelection() ? "Copy Selected Lines" : "Copy Line") { actions.copy(false) }
                Button("Copy as Diff") { actions.copy(true) }
                Button("Copy Reference (path:line)") { actions.copyReference() }
            }
    }
}

private extension LineKind {
    var marker: String {
        switch self {
        case .addition: "+"
        case .deletion: "-"
        default: " "
        }
    }

    var background: Color {
        switch self {
        case .addition: Palette.addBg
        case .deletion: Palette.delBg
        default: .clear
        }
    }

    var gutterColor: Color {
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

