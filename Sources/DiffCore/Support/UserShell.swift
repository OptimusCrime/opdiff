import Foundation

public enum UserShell {
    /// The user's shell (`$SHELL`), falling back to zsh, macOS's default.
    public static var path: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }
}
