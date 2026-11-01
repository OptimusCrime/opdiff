import Foundation

public struct GitError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

/// Thin wrapper around the `git` command line tool. All calls are blocking;
/// call them off the main thread.
public enum Git {
    static let executable: String = {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/git"
    }()

    @discardableResult
    public static func run(_ args: [String], in dir: URL, allowedExitCodes: Set<Int32> = [0]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "core.quotePath=false", "-c", "color.ui=never",
                             "-c", "diff.suppressBlankEmpty=false"] + args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"  // don't take the index lock while the user works
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw GitError(message: "Could not run git: \(error.localizedDescription)")
        }

        // Drain stderr concurrently so a chatty git can't deadlock on a full pipe.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard allowedExitCodes.contains(process.terminationStatus) else {
            let msg = String(decoding: errBox.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: msg.isEmpty
                ? "git \(args.joined(separator: " ")) failed (exit \(process.terminationStatus))"
                : msg)
        }
        return data
    }

    /// Fixed a/ b/ prefixes, regardless of diff.noprefix / diff.mnemonicPrefix in the user's config.
    static let diffFlags = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/"]

    static func string(_ args: [String], in dir: URL) throws -> String {
        String(decoding: try run(args, in: dir), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func repositoryInfo(at url: URL) throws -> RepositoryInfo {
        let root = URL(fileURLWithPath: try string(["rev-parse", "--show-toplevel"], in: url))

        let refs = try string(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"],
            in: root)
        var local: [String] = [], remote: [String] = []
        for ref in refs.split(separator: "\n").map(String.init) {
            if ref.hasPrefix("refs/heads/") {
                local.append(String(ref.dropFirst("refs/heads/".count)))
            } else if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
                remote.append(String(ref.dropFirst("refs/remotes/".count)))
            }
        }

        let current = try? string(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)

        // Prefer what GitHub would use as the PR base: the remote's default branch.
        var defaultBase = try? string(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root)
        if defaultBase?.isEmpty ?? true {
            defaultBase = ["origin/main", "origin/master"].first(where: remote.contains)
                ?? ["main", "master", "develop", "trunk"].first(where: local.contains)
        }

        return RepositoryInfo(root: root, branches: local + remote,
                              currentBranch: current?.isEmpty == false ? current : nil,
                              defaultBase: defaultBase)
    }

    /// Same semantics as GitHub's compare view (`base...head`): changes on `head`
    /// since it diverged from `base`. With `includeWorkingTree`, `head` must be the
    /// checked-out branch, and staged, unstaged and untracked changes are included.
    public static func compare(repo: URL, base: String, head: String, includeWorkingTree: Bool) throws -> Comparison {
        for ref in [base, head] {
            guard (try? run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repo)) != nil else {
                throw GitError(message: "Unknown branch or revision: \(ref)")
            }
        }

        let mergeBase = (try? string(["merge-base", base, head], in: repo)).flatMap { $0.isEmpty ? nil : $0 }
        var diffArgs = ["diff"] + diffFlags + ["--find-renames", mergeBase ?? base]
        if !includeWorkingTree { diffArgs.append(head) }
        diffArgs.append("--")

        var files = DiffParser.parse(try run(diffArgs, in: repo))
        if includeWorkingTree {
            files += try untrackedFiles(in: repo)
            files.sort { $0.path < $1.path }
        }

        let commits = try log(["\(base)..\(head)"], in: repo)
        return Comparison(files: files, commits: commits, mergeBase: mergeBase)
    }

    /// The most recent commits reachable from `ref`, newest first.
    public static func history(repo: URL, ref: String, limit: Int = 300) throws -> [Commit] {
        try log(["-n", String(limit), ref], in: repo)
    }

    static func log(_ revisionArgs: [String], in repo: URL) throws -> [Commit] {
        let out = try string(["log", "--format=%H%x1f%h%x1f%an%x1f%ar%x1f%s"] + revisionArgs + ["--"], in: repo)
        return out.split(separator: "\n").compactMap { line -> Commit? in
            let f = line.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            return Commit(sha: f[0], hash: f[1], subject: f[4], author: f[2], date: f[3])
        }
    }

    static func untrackedFiles(in repo: URL) throws -> [FileDiff] {
        let data = try run(["ls-files", "--others", "--exclude-standard", "-z"], in: repo)
        let paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return paths.prefix(500).flatMap { path -> [FileDiff] in
            guard let out = try? run(["diff"] + diffFlags + ["--no-index", "--", "/dev/null", path],
                                     in: repo, allowedExitCodes: [0, 1]) else { return [] }
            return DiffParser.parse(out)
        }
    }
}
