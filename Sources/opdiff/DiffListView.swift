import AppKit
import DiffCore
import SwiftUI

private let mono = Font.system(size: 12, design: .monospaced)

private enum Palette {
    static let addBg = Color.green.opacity(0.14)
    static let addGutter = Color.green.opacity(0.24)
    static let delBg = Color.red.opacity(0.14)
    static let delGutter = Color.red.opacity(0.24)
    static let hunk = Color.blue.opacity(0.10)
    static let empty = Color.primary.opacity(0.04)
    static let border = Color(nsColor: .separatorColor)
    static let header = Color(nsColor: .windowBackgroundColor)
}

/// All files in one long scroll, like GitHub's "Files changed" tab.
struct DiffListView: View {
    let model: CompareModel
    @Binding var selection: String?
    let splitView: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    SummaryHeader(model: model).padding(.bottom, 16)
                    ForEach(model.files) { file in
                        Section {
                            fileBody(file)
                        } header: {
                            FileHeader(file: file, model: model).id(file.id)
                        }
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
        }
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
                let gutter = CGFloat(max(String(file.maxLineNumber).count, 2)) * 7.5
                ForEach(rows.indices, id: \.self) { i in
                    RowView(row: rows[i], gutter: gutter).cardSides()
                }
            }
        }
        Rectangle().fill(Palette.border).frame(height: 1).padding(.bottom, 16)
    }
}

private struct SummaryHeader: View {
    let model: CompareModel
    @State private var showCommits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Comparing changes").font(.title2.bold())
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            if !model.base.isEmpty, !model.head.isEmpty {
                Text("Changes on \(Text(model.head).bold()) since it diverged from \(Text(model.base).bold())\(model.effectiveUncommitted ? ", including uncommitted work" : "").")
                    .foregroundStyle(.secondary)
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
                     : model.base.isEmpty || model.head.isEmpty
                     ? "Select a base and a compare branch."
                     : model.base == model.head && !model.effectiveUncommitted
                     ? "Choose different branches to compare."
                     : "There isn't anything to compare — the branches are identical.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
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

private struct RowView: View {
    let row: DiffRow
    let gutter: CGFloat

    var body: some View {
        switch row {
        case .hunk(let header):
            Text(header)
                .font(mono)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.hunk)
        case .line(let line):
            UnifiedLine(line: line, gutter: gutter)
        case .pair(let old, let new):
            HStack(spacing: 0) {
                SplitCell(line: old, number: old?.oldNumber, gutter: gutter)
                Rectangle().fill(Palette.border).frame(width: 1)
                SplitCell(line: new, number: new?.newNumber, gutter: gutter)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UnifiedLine: View {
    let line: DiffLine
    let gutter: CGFloat

    var body: some View {
        if line.kind == .noNewline {
            Text(line.text).font(mono.italic()).foregroundStyle(.secondary)
                .padding(.leading, gutter * 2 + 40).padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 0) {
                LineNumber(number: line.oldNumber, width: gutter, background: line.kind.gutterColor)
                LineNumber(number: line.newNumber, width: gutter, background: line.kind.gutterColor)
                CodeText(line: line)
            }
            .background(line.kind.background)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SplitCell: View {
    let line: DiffLine?
    let number: Int?
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let line {
                LineNumber(number: number, width: gutter, background: line.kind.gutterColor)
                CodeText(line: line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(line?.kind.background ?? Palette.empty)
    }
}

private struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    let background: Color

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(mono)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(background)
            .textSelection(.disabled)
    }
}

private struct CodeText: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.kind.marker)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(mono)
        .padding(.vertical, 1)
        .padding(.trailing, 8)
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

private extension View {
    /// Left/right borders so consecutive rows read as one card per file.
    func cardSides() -> some View {
        overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1) }
    }
}
