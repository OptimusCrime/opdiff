import Foundation

/// What is being compared, for the prompt.
public struct ReviewContext: Sendable {
    public var base: String
    public var head: String
    public var mergeBase: String?
    public var includesWorkingTree: Bool
    /// Only the working tree compared with `HEAD` (base and the branch's commits left out).
    public var uncommittedOnly: Bool
    public var commitCount: Int
    public var focus: String

    public init(
        base: String, head: String, mergeBase: String?, includesWorkingTree: Bool,
        commitCount: Int, focus: String, uncommittedOnly: Bool = false
    ) {
        self.base = base
        self.head = head
        self.mergeBase = mergeBase
        self.includesWorkingTree = includesWorkingTree
        self.uncommittedOnly = uncommittedOnly
        self.commitCount = commitCount
        self.focus = focus
    }

    /// The git command that reproduces the diff for one path.
    func diffCommand(for path: String) -> String {
        if uncommittedOnly { return "git diff HEAD -- '\(path)'" }
        let from = mergeBase ?? base
        return includesWorkingTree ? "git diff \(from) -- '\(path)'" : "git diff \(from) \(head) -- '\(path)'"
    }

    /// One sentence fragment describing what is compared.
    func comparisonDescription(untracked: Bool) -> String {
        if uncommittedOnly {
            return "uncommitted changes on `\(head)` since its last commit (staged, unstaged"
                + (untracked ? " and untracked" : "") + " changes in the working tree compared with HEAD)"
        }
        return "changes on `\(head)` since it diverged from `\(base)`"
            + (mergeBase.map { " (merge base \($0.prefix(10)))" } ?? "")
            + (includesWorkingTree
                ? ", including uncommitted" + (untracked ? " and untracked" : "") + " changes in the working tree" : "")
    }
}

public enum ReviewPrompt {
    /// Diffs larger than this (in characters) are partly left for Claude to fetch with git.
    public static let maxDiffCharacters = 250_000

    public static func build(files: [FileDiff], context: ReviewContext) -> String {
        var prompt = """
            You are helping a developer review a code change before they open a pull request. \
            Your job is to point their attention at the lines that matter. You will not edit anything.

            Comparison: \(context.comparisonDescription(untracked: true)). \
            \(context.uncommittedOnly ? "" : "\(context.commitCount) commit(s), ")\(files.count) file(s) changed.

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

        prompt +=
            "\n# Diff\n\nColumns: OLD line number, NEW line number, marker (+ added, - deleted, space unchanged), code.\n"
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
            prompt +=
                "\n# Files not included above (diff too large)\n\nInspect these with the command shown if relevant:\n"
            for file in omitted {
                prompt +=
                    "- \(file.path) (+\(file.additions) −\(file.deletions)): `\(context.diffCommand(for: file.path))`\n"
            }
        }
        return prompt
    }

    public static func render(_ file: FileDiff) -> String {
        var out = "\nFILE: \(file.path)"
        switch file.status {
        case .added: out += " (new file)"
        case .deleted: out += " (deleted)"
        case .renamed, .copied:
            out += " (\(file.status == .renamed ? "renamed" : "copied") from \(file.oldPath ?? "?"))"
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
                    out += renderLine(line) + "\n"
                }
            }
        }
        return out
    }

    static func renderLine(_ line: DiffLine) -> String {
        let old = line.oldNumber.map { String($0) } ?? ""
        let new = line.newNumber.map { String($0) } ?? ""
        let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " "
        return pad(old) + " " + pad(new) + " " + marker + " " + line.text
    }

    private static func pad(_ s: String) -> String {
        String(repeating: " ", count: max(0, 5 - s.count)) + s
    }
}

/// Prompt for "Ask Claude about these lines".
public enum QuestionPrompt {
    /// The file's diff is included for context up to this many characters.
    static let maxFileDiffCharacters = 60_000

    public static func build(file: FileDiff, selected: [DiffLine], question: String, context: ReviewContext) -> String {
        var prompt = """
            A developer is reviewing a code change and has a question about some lines in it. \
            Answer the question directly and concisely (usually a few short paragraphs at most). \
            Use Markdown for code and emphasis. You will not edit anything.

            Comparison: \(context.comparisonDescription(untracked: false)).

            You may use Read/Grep/Glob to look at surrounding code, and `git diff`, `git show`, `git log` for \
            history. Files on disk reflect the current working tree.

            # The lines the question is about (\(file.path))

            Columns: OLD line number, NEW line number, marker (+ added, - deleted, space unchanged), code.

            """
        for line in selected where line.kind != .noNewline {
            prompt += ReviewPrompt.renderLine(line) + "\n"
        }
        prompt += "\n# Question\n\n\(question.trimmingCharacters(in: .whitespacesAndNewlines))\n"

        let fileDiff = ReviewPrompt.render(file)
        if fileDiff.count <= maxFileDiffCharacters {
            prompt += "\n# The whole diff of this file, for context\n" + fileDiff
        } else {
            prompt +=
                "\n# Context\n\nThe file's diff is large; inspect it with `\(context.diffCommand(for: file.path))` if needed.\n"
        }
        return prompt
    }
}
