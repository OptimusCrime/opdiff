import AppKit
import DiffCore
import SwiftUI

/// All files in one long scroll, like GitHub's "Files changed" tab.
struct DiffListView: View {
    let model: CompareModel
    @Binding var selection: String?
    let wrapLines: Bool
    let onOpenReview: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var splitView: Bool { model.splitView }

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
                if let id {
                    model.noteFileShown(id)
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: model.jumpRequest) { _, request in
                if let request { scroll(to: request, proxy: proxy) }
            }
        }
    }

    /// Scroll to a file, or to a row in it.
    ///
    /// The diff is a LazyVStack, so rows far away haven't been laid out and their heights
    /// are estimates: a single scrollTo can land off target. Scroll again once layout has
    /// settled (and after a collapsed file has been expanded).
    private func scroll(to request: JumpRequest, proxy: ScrollViewProxy) {
        guard let row = request.row else {
            proxy.scrollTo(request.fileID, anchor: .top)
            return
        }
        let rowID = RowKey(fileID: request.fileID, index: row)
        // Below the sticky file header rather than underneath it.
        let anchor = UnitPoint(x: 0, y: 0.25)
        proxy.scrollTo(rowID, anchor: anchor)
        Task { @MainActor in
            for delay in [60, 180, 350] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard model.jumpRequest == request else { return }  // a newer jump took over
                proxy.scrollTo(rowID, anchor: anchor)
            }
        }
    }

    private func rowActions(file: FileDiff, index: Int) -> RowActions {
        let fileID = file.id
        let split = splitView
        let target = (fileID: fileID, index: index, split: split)
        return RowActions(
            select: { extend in model.selectRow(fileID: fileID, index: index, split: split, extend: extend) },
            copy: { asDiff in model.copyLines(asDiff: asDiff, fallback: target) },
            copyReference: { model.copyReference(fallback: target) },
            hasSelection: { model.hasLineSelection },
            ask: { model.beginQuestion(fallback: target) },
            openInEditor: { model.openInEditor(fileID: fileID, index: index) },
            canOpenInEditor: file.status != .deleted,
            expand: { full in model.expandContext(file, full: full) },
            card: cardActions)
    }

    private var cardActions: CardActions {
        CardActions(
            toggleResolved: { model.toggleResolved($0) },
            remove: { model.removeQuestion($0) },
            cancel: { model.cancelQuestion($0) })
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
                NoteRow(
                    text: "Large diff (\(file.lineCount) lines) is hidden.",
                    action: ("Load diff", { model.expandLarge(file) }))
            } else {
                let rows = splitView ? file.splitRows : file.unifiedRows
                let digits = max(String(file.maxLineNumber).count, 2)
                let highlight = model.highlighted(file, dark: colorScheme == .dark)
                let layout = model.annotationLayout(for: file)
                let flashed = model.flashedAnnotationID
                let marks = RowContent.Marks(
                    file: file, hits: model.searchHits[file.id],
                    currentMatch: model.currentMatch.flatMap { $0.fileID == file.id ? $0 : nil },
                    canExpand: model.canExpandContext(file),
                    resolved: model.storedReview?.resolved ?? [], pending: model.pendingQuestionIDs)
                ForEach(layout?.unplaced ?? []) { annotation in
                    AnnotationCard(
                        annotation: annotation, note: "not on a changed line",
                        isFlashing: annotation.id == flashed,
                        isResolved: model.isResolved(annotation), isPending: model.isPending(annotation),
                        actions: cardActions
                    )
                    .cardSides()
                }
                ForEach(RowKeys(fileID: file.id, count: rows.count), id: \.self) { key in
                    let i = key.index
                    let content = RowContent.make(
                        rows[i], highlight: highlight, layout: layout, marks: marks,
                        flashedID: flashed,
                        isSelected: model.isRowSelected(fileID: file.id, index: i, split: splitView))
                    DiffRowView(
                        content: content, digits: digits, wrap: wrapLines,
                        actions: rowActions(file: file, index: i)
                    )
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
                if model.onlyUncommitted {
                    Text("Uncommitted changes on \(head) since the last commit.")
                        .foregroundStyle(.secondary)
                } else if model.mode == .commit {
                    let commit = model.commits.first
                    let merge = commit?.isMerge == true ? " (merge, compared with its first parent)" : ""
                    Text("Changes in \(head)\(merge): \(commit?.subject ?? "")")
                        .foregroundStyle(.secondary)
                } else if model.mode == .branches {
                    Text("Changes on \(head) since it diverged from \(base)\(extra).")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Changes from \(base) to \(head)\(extra).")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Button {
                    showCommits.toggle()
                } label: {
                    Label(
                        "\(model.commits.count) commit\(model.commits.count == 1 ? "" : "s")",
                        systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.link)
                .disabled(model.commits.isEmpty)
                .popover(isPresented: $showCommits) {
                    CommitList(commits: model.commits) { commit in
                        showCommits = false
                        Task { await model.showSingleCommit(commit) }
                    }
                }

                Label(
                    "\(model.files.count) file\(model.files.count == 1 ? "" : "s") changed", systemImage: "doc.on.doc")
                DiffStat(additions: model.totalAdditions, deletions: model.totalDeletions)
                    .monospacedDigit()
                if let mb = model.mergeBase {
                    Text("merge base \(String(mb.prefix(8)))").font(.callout.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle(
                    "Hide whitespace changes",
                    isOn: Binding(
                        get: { model.ignoreWhitespace },
                        set: { model.ignoreWhitespace = $0 })
                )
                .toggleStyle(.checkbox)
                .help("Ignore changes in whitespace (git diff -w)")
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.files.isEmpty, !model.isLoading {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            ReviewPanel(model: model, onOpenReview: onOpenReview)
                .padding(.top, 4)
        }
        .textSelection(.disabled)
    }

    private var emptyMessage: String {
        if model.branches.isEmpty {
            return "This repository has no commits yet — commit something first, then compare branches."
        }
        switch model.mode {
        case .commit:
            return model.head.isEmpty ? "Select a commit." : "This commit has no changes to show."
        case .commits where model.base.isEmpty:
            return "Select a base commit, then the commit to compare it with."
        case .commits where model.head.isEmpty:
            return "There are no commits after the base commit on \(model.commitBranch)."
        default: break
        }
        if model.base.isEmpty || model.head.isEmpty { return "Select a base and a compare branch." }
        if model.onlyUncommitted { return "There are no uncommitted changes." }
        return model.base == model.head && !model.effectiveUncommitted
            ? "Choose different branches to compare."
            : "There isn't anything to compare — the branches are identical."
    }
}

private struct CommitList: View {
    let commits: [Commit]
    let onSelect: (Commit) -> Void

    var body: some View {
        List(commits) { c in
            Button {
                onSelect(c)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.subject).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(c.hash).font(.caption.monospaced())
                        Text("\(c.author) · \(c.date)").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show only this commit")
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
            Button {
                model.toggleCollapsed(file)
            } label: {
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
                Button("Open in Editor") { model.openInEditor(fileID: file.id, index: nil) }
                    .disabled(file.status == .deleted)
                Button("Open with Default App") { if let url = model.fileURL(file) { NSWorkspace.shared.open(url) } }
                    .disabled(file.status == .deleted)
                if model.canExpandContext(file) {
                    Divider()
                    Button("Show More Context") { model.expandContext(file, full: false) }
                    Button("Show Full File") { model.expandContext(file, full: true) }
                }
                Divider()
                Button("Reveal in Finder") {
                    if let url = model.fileURL(file) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(file.status == .deleted)
                Button("Copy Path") { Pasteboard.copy(file.path) }
            } label: {
                Image(systemName: "ellipsis")
            }
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
