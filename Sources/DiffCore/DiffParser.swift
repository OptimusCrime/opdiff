import Foundation

/// Parses the output of `git diff` (unified format) into files, hunks and lines.
public enum DiffParser {
    public static func parse(_ data: Data) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileBuilder?
        var inHunk = false
        var oldNo = 0, newNo = 0

        // Split on raw bytes so "\r\n" and invalid UTF-8 never trip us up.
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = String(decoding: raw, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.hasPrefix("diff --git ") {
                if let b = current { files.append(b.build()) }
                current = FileBuilder(gitHeader: String(line.dropFirst("diff --git ".count)))
                inHunk = false
                continue
            }
            guard let b = current else { continue }

            if line.hasPrefix("@@ ") {
                (oldNo, newNo) = hunkStarts(line)
                b.hunks.append(Hunk(header: line, lines: []))
                inHunk = true
                continue
            }

            if inHunk, let first = line.first {
                let text = String(line.dropFirst())
                switch first {
                case " ":
                    b.append(DiffLine(kind: .context, text: text, oldNumber: oldNo, newNumber: newNo))
                    oldNo += 1; newNo += 1
                    continue
                case "+":
                    b.append(DiffLine(kind: .addition, text: text, oldNumber: nil, newNumber: newNo))
                    newNo += 1
                    continue
                case "-":
                    b.append(DiffLine(kind: .deletion, text: text, oldNumber: oldNo, newNumber: nil))
                    oldNo += 1
                    continue
                case "\\":
                    b.append(DiffLine(kind: .noNewline, text: line, oldNumber: nil, newNumber: nil))
                    continue
                default:
                    inHunk = false
                }
            }

            // Extended header lines.
            if line.hasPrefix("new file mode") {
                b.status = .added
            } else if line.hasPrefix("deleted file mode") {
                b.status = .deleted
            } else if line.hasPrefix("rename from ") {
                b.oldPath = String(line.dropFirst("rename from ".count)); b.status = .renamed
            } else if line.hasPrefix("rename to ") {
                b.newPath = String(line.dropFirst("rename to ".count)); b.status = .renamed
            } else if line.hasPrefix("copy from ") {
                b.oldPath = String(line.dropFirst("copy from ".count)); b.status = .copied
            } else if line.hasPrefix("copy to ") {
                b.newPath = String(line.dropFirst("copy to ".count)); b.status = .copied
            } else if line.hasPrefix("--- ") {
                b.oldPath = cleanPath(String(line.dropFirst(4)), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                b.newPath = cleanPath(String(line.dropFirst(4)), prefix: "b/")
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                b.isBinary = true
            }
        }
        if let b = current { files.append(b.build()) }
        return files
    }

    /// "@@ -12,7 +14,8 @@ func foo()" -> (12, 14)
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (0, 0) }
        func start(_ s: Substring) -> Int {
            Int(s.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start(parts[1]), start(parts[2]))
    }

    static func cleanPath(_ raw: String, prefix: String) -> String? {
        var p = raw
        if p.hasSuffix("\t") { p.removeLast() }
        if p.count >= 2, p.hasPrefix("\""), p.hasSuffix("\"") { p = String(p.dropFirst().dropLast()) }
        if p == "/dev/null" { return nil }
        if p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        return p
    }

    /// Best-effort paths from "a/foo b/foo"; only used when there are no ---/+++ lines
    /// (binary files, pure renames, mode changes).
    static func pathsFromGitHeader(_ s: String) -> (String?, String?) {
        let chars = Array(s)
        if chars.count % 2 == 1 {
            let half = chars.count / 2
            let a = String(chars[..<half]), b = String(chars[(half + 1)...])
            if a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) {
                return (String(a.dropFirst(2)), String(b.dropFirst(2)))
            }
        }
        if let r = s.range(of: " b/") {
            return (cleanPath(String(s[..<r.lowerBound]), prefix: "a/"), String(s[r.upperBound...]))
        }
        return (s, s)
    }

    static func splitRows(_ hunks: [Hunk]) -> [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in hunks {
            rows.append(.hunk(hunk.header))
            var dels: [DiffLine] = [], adds: [DiffLine] = []
            func flush() {
                for i in 0..<max(dels.count, adds.count) {
                    rows.append(.pair(i < dels.count ? dels[i] : nil, i < adds.count ? adds[i] : nil))
                }
                dels.removeAll(); adds.removeAll()
            }
            for line in hunk.lines {
                switch line.kind {
                case .deletion:
                    if !adds.isEmpty { flush() }
                    dels.append(line)
                case .addition:
                    adds.append(line)
                case .context:
                    flush(); rows.append(.pair(line, line))
                case .noNewline:
                    flush(); rows.append(.line(line))
                }
            }
            flush()
        }
        return rows
    }
}

final class FileBuilder {
    var oldPath: String?
    var newPath: String?
    var status: FileStatus = .modified
    var isBinary = false
    var hunks: [Hunk] = []
    var additions = 0
    var deletions = 0

    init(gitHeader: String) {
        (oldPath, newPath) = DiffParser.pathsFromGitHeader(gitHeader)
    }

    func append(_ line: DiffLine) {
        guard !hunks.isEmpty else { return }
        hunks[hunks.count - 1].lines.append(line)
        if line.kind == .addition { additions += 1 }
        if line.kind == .deletion { deletions += 1 }
    }

    func build() -> FileDiff {
        if status == .added { oldPath = nil }
        if status == .deleted { newPath = nil }
        if status == .modified, let o = oldPath, let n = newPath, o != n { status = .renamed }

        var hasher = Hasher()
        var maxLine = 0
        for hunk in hunks {
            for line in hunk.lines {
                hasher.combine(line)
                maxLine = max(maxLine, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        let unified = hunks.flatMap { [DiffRow.hunk($0.header)] + $0.lines.map(DiffRow.line) }
        return FileDiff(
            oldPath: oldPath, newPath: newPath, status: status, isBinary: isBinary, hunks: hunks,
            additions: additions, deletions: deletions, contentHash: hasher.finalize(),
            maxLineNumber: maxLine, unifiedRows: unified, splitRows: DiffParser.splitRows(hunks))
    }
}
