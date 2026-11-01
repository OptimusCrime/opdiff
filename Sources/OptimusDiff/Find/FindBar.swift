import AppKit
import DiffCore
import SwiftUI

/// ⌘F bar above the diff: finds text in every shown line.
struct FindBar: View {
    @Bindable var model: CompareModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in diff", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
                .focused($focused)
                // Return: next match; ⇧Return: previous.
                .onSubmit { model.findNext(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { model.closeFind() }
            Text(status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            HStack(spacing: 2) {
                Button {
                    model.findNext(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match (⇧⌘G)")
                Button {
                    model.findNext(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next match (⌘G)")
            }
            .disabled(model.searchMatches.isEmpty)
            Spacer()
            Button("Done") { model.closeFind() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onChange(of: model.findFocusToken) { focused = true }
    }

    private var status: String {
        let count = model.searchMatches.count
        if model.searchQuery.isEmpty { return "" }
        if count == 0 { return "No matches" }
        let total = count >= CompareModel.searchLimit ? "\(count)+" : "\(count)"
        return model.currentMatchIndex.map { "\($0 + 1) of \(total)" } ?? "\(total) matches"
    }
}
