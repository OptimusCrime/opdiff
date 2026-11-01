import AppKit
import DiffCore
import SwiftUI

@main
struct OptimusDiffApp: App {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare binary (e.g. `swift run`) instead of the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
