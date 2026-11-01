import Foundation

/// What is being compared, for the prompt.
public struct ReviewContext: Sendable {
    public var base: String
    public var head: String
    public var mergeBase: String?
    public var includesWorkingTree: Bool
    public var commitCount: Int
    public var focus: String

    public init(base: String, head: String, mergeBase: String?, includesWorkingTree: Bool,
                commitCount: Int, focus: String) {
        self.base = base
        self.head = head
        self.mergeBase = mergeBase
        self.includesWorkingTree = includesWorkingTree
        self.commitCount = commitCount
        self.focus = focus
    }

    /// The git command that reproduces the diff for one path.
    func diffCommand(for path: String) -> String {
        let from = mergeBase ?? base
        return includesWorkingTree ? "git diff \(from) -- '\(path)'" : "git diff \(from) \(head) -- '\(path)'"
    }
}

public enum ReviewPrompt {
    /// Diffs larger than this (in characters) are partly left for Claude to fetch with git.
    public static let maxDiffCharacters = 250_000

    public static func build(files: [FileDiff], context: ReviewContext) -> String {
        var prompt = """
        You are helping a developer review a code change before they open a pull request. \
        Your job is to point their attention at the lines that matter. You will not edit anything.

        Comparison: changes on `\(context.head)` since it diverged from `\(context.base)`\
        \(context.mergeBase.map { " (merge base \($0.prefix(10)))" } ?? "")\
        \(context.includesWorkingTree ? ", including uncommitted and untracked changes in the working tree" : "")\
        . \(context.commitCount) commit(s), \(files.count) file(s) changed.

        Return a short `summary` (2–4 sentences: what the change does and the main risks) and a list of \
        `annotations`. Each annotation marks a range of lines in one file:
        - `kind`: "important" for likely bugs, risky logic, security or data-loss issues, breaking changes; \
        "attention" for subtle code that deserves a careful look; "info" for context that helps the reviewer \
        understand the change.
        - `file`: the path exactly as shown after "FILE:".
        - `side` + `startLine`/`endLine`: use side "new" with the NEW line numbers for added (+) or \
        unchanged lines, and side "old" with the OLD line numbers for deleted (-) lines. Only reference lines \
        that appear in the diff below; the numbers are printed in the OLD and NEW columns.
        - `comment`: 1–3 concise sentences saying why these lines matter.

        Prefer a handful of high-signal annotations over many small ones (usually no more than 15–20). \
        Do not annotate formatting, renames or trivial changes. If nothing stands out, return few or no \
        annotations and say so in the summary.

        You may use Read/Grep/Glob to look at surrounding code, and `git diff`, `git show`, `git log` for \
        history. Files on disk reflect the current working tree, which may differ from the compared \
        version; use `git show <ref>:<path>` to see a file at a specific commit.

        """
        let focus = context.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !focus.isEmpty {
            prompt += "\nThe developer asked you to focus on: \(focus)\n"
        }

        prompt += "\n# Diff\n\nColumns: OLD line number, NEW line number, marker (+ added, - deleted, space unchanged), code.\n"
        var used = prompt.count
        var omitted: [FileDiff] = []
        for file in files {
            let rendered = render(file)
            if used + rendered.count > maxDiffCharacters {
                omitted.append(file)
                continue
            }
            prompt += rendered
            used += rendered.count
        }
        if !omitted.isEmpty {
            prompt += "\n# Files not included above (diff too large)\n\nInspect these with the command shown if relevant:\n"
            for file in omitted {
                prompt += "- \(file.path) (+\(file.additions) −\(file.deletions)): `\(context.diffCommand(for: file.path))`\n"
            }
        }
        return prompt
    }

    static func render(_ file: FileDiff) -> String {
        var out = "\nFILE: \(file.path)"
        switch file.status {
        case .added: out += " (new file)"
        case .deleted: out += " (deleted)"
        case .renamed, .copied: out += " (\(file.status == .renamed ? "renamed" : "copied") from \(file.oldPath ?? "?"))"
        case .modified: break
        }
        out += "\n"
        if file.isBinary { return out + "(binary file, not shown)\n" }
        if file.hunks.isEmpty { return out + "(no content changes)\n" }
        for hunk in file.hunks {
            out += hunk.header + "\n"
            for line in hunk.lines {
                switch line.kind {
                case .noNewline:
                    out += "            \(line.text)\n"
                default:
                    let old = line.oldNumber.map { String($0) } ?? ""
                    let new = line.newNumber.map { String($0) } ?? ""
                    let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " "
                    out += pad(old) + " " + pad(new) + " " + marker + " " + line.text + "\n"
                }
            }
        }
        return out
    }

    private static func pad(_ s: String) -> String {
        String(repeating: " ", count: max(0, 5 - s.count)) + s
    }
}

/// Runs a Claude Code command (e.g. `claude`, or an alias such as `pclaude`) through the
/// user's login shell, so aliases and PATH from their shell config work.
public final class ClaudeReviewRun: @unchecked Sendable {
    private let command: String
    private let directory: URL
    private let prompt: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init(command: String, directory: URL, prompt: String) {
        self.command = command
        self.directory = directory
        self.prompt = prompt
    }

    /// Arguments appended to the user's command. Read-only tools; Bash limited to git
    /// read commands; no MCP servers, skills or saved session.
    static let arguments = """
    -p --output-format json --json-schema "$OPDIFF_REVIEW_SCHEMA" \
    --tools Read Grep Glob Bash \
    --allowedTools Read Grep Glob "Bash(git diff *)" "Bash(git show *)" "Bash(git log *)" \
    --strict-mcp-config --disable-slash-commands --no-session-persistence
    """

    /// Blocking; call off the main thread.
    public func run() throws -> ClaudeResult {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l: login profile (PATH), -i: interactive rc file (aliases such as `pclaude`).
        process.arguments = ["-l", "-i", "-c", "\(command) \(Self.arguments)"]
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["OPDIFF_REVIEW_SCHEMA"] = ReviewSchema.json
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
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
            return try ClaudeOutput.parse(output)
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
