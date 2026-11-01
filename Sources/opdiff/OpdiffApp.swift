import AppKit
import SwiftUI

@main
struct OpdiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = CompareModel(launch: .parse(CommandLine.arguments))

    var body: some Scene {
        Window("opdiff", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.chooseRepository() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
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
