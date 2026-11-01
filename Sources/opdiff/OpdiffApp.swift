import AppKit
import DiffCore
import SwiftUI

@main
struct OpdiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = CompareModel(launch: .parse(CommandLine.arguments))
    @AppStorage("wrapLines") private var wrapLines = true

    var body: some Scene {
        Window("OptimusDiff", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.chooseRepository() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Diff…") { model.showFind() }
                    .keyboardShortcut("f")
                    .disabled(model.files.isEmpty)
                Button("Find Next") { model.findNext(forward: true) }
                    .keyboardShortcut("g")
                    .disabled(model.searchMatches.isEmpty)
                Button("Find Previous") { model.findNext(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.searchMatches.isEmpty)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Selected Lines") { model.copyLines(asDiff: false) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!model.hasLineSelection)
                Button("Copy Selected Lines as Diff") { model.copyLines(asDiff: true) }
                    .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                    .disabled(!model.hasLineSelection)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Wrap Long Lines", isOn: $wrapLines)
                    .keyboardShortcut("w", modifiers: [.command, .option])
                Toggle("Hide Whitespace Changes", isOn: $model.ignoreWhitespace)
                Toggle("Refresh Automatically", isOn: $model.autoRefresh)
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Swap Base and Compare") { model.swap() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Expand All Files") { model.expandAll() }
                Button("Collapse All Files") { model.collapseAll() }
                Divider()
            }
            // Single-letter shortcuts are handled by ContentView's key monitor (so they don't fire
            // while typing); the menu lists them.
            CommandMenu("Go") {
                Button("Next Change  (J)") { model.goToChange(forward: true) }
                Button("Previous Change  (K)") { model.goToChange(forward: false) }
                Divider()
                Button("Next Comment  (N)") { model.goToComment(forward: true) }
                Button("Previous Comment  (P)") { model.goToComment(forward: false) }
                Divider()
                Button("Toggle Viewed, Go to Next File  (V)") { model.toggleViewedAndAdvance() }
                Button("Open in Editor  (O)") { model.openCurrentInEditor() }
                Button("Ask Claude About Selected Lines…  (A)") { model.beginQuestion() }
                    .disabled(!model.hasLineSelection)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare binary (e.g. `swift run`) instead of the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
