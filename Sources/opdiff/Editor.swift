import AppKit

/// The editor that "Open in Editor" uses (chosen in Settings).
enum EditorChoice: String, CaseIterable, Identifiable {
    case vscode, cursor, zed, sublime, intellij, xcode, systemDefault, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .sublime: "Sublime Text"
        case .intellij: "IntelliJ IDEA"
        case .xcode: "Xcode"
        case .systemDefault: "Default app for the file type"
        case .custom: "Custom command"
        }
    }

    /// Short name for menus.
    var shortName: String {
        switch self {
        case .vscode: "VS Code"
        case .systemDefault: "Default App"
        case .custom: "Editor"
        default: label
        }
    }

    var bundleIDs: [String] {
        switch self {
        case .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .sublime: ["com.sublimetext.4", "com.sublimetext.3"]
        case .intellij: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .xcode: ["com.apple.dt.Xcode"]
        case .systemDefault, .custom: []
        }
    }

    var isInstalled: Bool {
        bundleIDs.isEmpty || bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// The saved choice, else the first installed editor.
    static var current: EditorChoice {
        if let raw = UserDefaults.standard.string(forKey: "editor"), let choice = EditorChoice(rawValue: raw) {
            return choice
        }
        return [.vscode, .cursor, .zed, .sublime, .intellij].first(where: \.isInstalled) ?? .systemDefault
    }
}

enum EditorOpener {
    /// Placeholders for the custom command: {file} (shell-quoted path) and {line}.
    static let defaultCustomCommand = "code -g {file}:{line}"

    static func open(_ file: URL, line: Int?, editor: EditorChoice = .current) {
        let path = file.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let query = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+"])) ?? path
        let lineSuffix = line.map { ":\($0)" } ?? ""

        switch editor {
        case .vscode: openURL("vscode://file\(encoded)\(lineSuffix)", fallback: file)
        case .cursor: openURL("cursor://file\(encoded)\(lineSuffix)", fallback: file)
        case .zed: openURL("zed://file\(encoded)\(lineSuffix)", fallback: file)
        case .sublime: openURL("subl://open?url=file://\(query)" + (line.map { "&line=\($0)" } ?? ""), fallback: file)
        case .intellij: openURL("idea://open?file=\(query)" + (line.map { "&line=\($0)" } ?? ""), fallback: file)
        case .xcode:
            run("/usr/bin/xed", (line.map { ["-l", String($0)] } ?? []) + [path])
        case .systemDefault:
            NSWorkspace.shared.open(file)
        case .custom:
            let template = UserDefaults.standard.string(forKey: "customEditorCommand")
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? defaultCustomCommand
            let command = template
                .replacingOccurrences(of: "{file}", with: shellQuote(path))
                .replacingOccurrences(of: "{line}", with: String(line ?? 1))
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            run(shell, ["-l", "-c", command])
        }
    }

    private static func openURL(_ string: String, fallback: URL) {
        guard let url = URL(string: string), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            NSWorkspace.shared.open(fallback)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
