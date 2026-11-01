import Foundation

/// Runs a Claude Code command (e.g. `claude`, or a shell alias for it) through the
/// user's login shell, so aliases and PATH from their shell config work.
public final class ClaudeReviewRun: @unchecked Sendable {
    private let command: String
    private let directory: URL
    private let prompt: String
    private let schema: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init(command: String, directory: URL, prompt: String, schema: String = ReviewSchema.json) {
        self.command = command
        self.directory = directory
        self.prompt = prompt
        self.schema = schema
    }

    /// Arguments appended to the user's command. Read-only tools; Bash limited to git
    /// read commands; no MCP servers, skills or saved session.
    static let arguments = """
        -p --output-format json --json-schema "$OPDIFF_REVIEW_SCHEMA" \
        --tools Read Grep Glob Bash \
        --allowedTools Read Grep Glob "Bash(git diff *)" "Bash(git show *)" "Bash(git log *)" \
        --strict-mcp-config --disable-slash-commands --no-session-persistence
        """

    /// Runs a review. Blocking; call off the main thread.
    public func run() throws -> ClaudeResult { try execute(ClaudeOutput.parse) }

    /// Runs a question (create the run with `AnswerSchema.json`). Blocking.
    public func runAnswer() throws -> ClaudeAnswer { try execute(ClaudeOutput.parseAnswer) }

    private func execute<T>(_ parse: (Data) throws -> T) throws -> T {
        let shell = UserShell.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l: login profile (PATH), -i: interactive rc file (shell aliases).
        process.arguments = ["-l", "-i", "-c", "\(command) \(Self.arguments)"]
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["OPDIFF_REVIEW_SCHEMA"] = schema
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        lock.unlock()

        do { try process.run() } catch {
            throw GitError(message: "Couldn't start \(shell): \(error.localizedDescription)")
        }

        let writer = Thread { [prompt] in
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let errBuffer = ErrorBuffer()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            errBuffer.data = stderr.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        process.waitUntilExit()

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }

        do {
            return try parse(output)
        } catch {
            // Prefer the CLI's own error message (e.g. command not found, not logged in).
            let errText = String(decoding: errBuffer.data, as: UTF8.self)
                .split(separator: "\n")
                .filter { !$0.contains("can't change option") }
                .suffix(8)
                .joined(separator: "\n")
            if process.terminationStatus != 0 || output.isEmpty {
                throw GitError(message: "`\(command)` failed (exit \(process.terminationStatus)).\n\(errText)")
            }
            throw error
        }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        // Stop Claude itself (a child of the shell), then the shell.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }
}

private final class ErrorBuffer: @unchecked Sendable { var data = Data() }
