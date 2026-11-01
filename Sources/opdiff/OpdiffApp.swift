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
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Swap Base and Compare") { model.swap() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Expand All Files") { model.expandAll() }
                Button("Collapse All Files") { model.collapseAll() }
                Divider()
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

    var body: some View {
        Form {
            Section {
                Picker("Diff algorithm", selection: $model.diffAlgorithm) {
                    ForEach(DiffAlgorithm.allCases) { Text($0.label).tag($0) }
                }
                Text("Passed to each git command OptimusDiff runs; your git config is not changed. "
                     + "Histogram and patience can give nicer diffs but are much slower on large changes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Wrap long lines", isOn: $wrapLines)
                Text("With wrapping off every line has the same height, which keeps the view compact and jumps predictable. Long lines are cut off (copy a line to get all of it). Scrolling is not faster: cutting lines costs about as much as wrapping them.")
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
