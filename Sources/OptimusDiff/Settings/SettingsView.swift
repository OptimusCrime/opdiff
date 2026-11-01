import DiffCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: CompareModel
    @AppStorage("wrapLines") private var wrapLines = true
    @AppStorage("editor") private var editor = EditorChoice.current.rawValue
    @AppStorage("customEditorCommand") private var customCommand = EditorOpener.defaultCustomCommand

    var body: some View {
        Form {
            Section {
                Picker("Open files in", selection: $editor) {
                    ForEach(EditorChoice.allCases) { choice in
                        Text(choice.label + (choice.isInstalled ? "" : " (not installed)")).tag(choice.rawValue)
                    }
                }
                if editor == EditorChoice.custom.rawValue {
                    TextField("Command", text: $customCommand)
                        .font(.system(.body, design: .monospaced))
                    Text(
                        "Run through your login shell. {file} is replaced with the file's path, {line} with the line number."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Toggle("Refresh automatically when files change", isOn: $model.autoRefresh)
                Toggle("Hide whitespace changes", isOn: $model.ignoreWhitespace)
            }
            Section {
                Picker("Diff algorithm", selection: $model.diffAlgorithm) {
                    ForEach(DiffAlgorithm.allCases) { Text($0.label).tag($0) }
                }
                Text(
                    "Passed to each git command OptimusDiff runs; your git config is not changed. "
                        + "Histogram and patience can give nicer diffs but are much slower on large changes."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Wrap long lines", isOn: $wrapLines)
                Text(
                    "With wrapping off every line has the same height, which keeps the view compact and jumps predictable. Long lines are cut off (copy a line to get all of it). Scrolling is not faster: cutting lines costs about as much as wrapping them."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
