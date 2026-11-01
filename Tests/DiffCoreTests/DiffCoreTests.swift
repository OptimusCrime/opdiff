import Foundation
import XCTest
@testable import DiffCore

final class DiffParserTests: XCTestCase {
    let sample = """
    diff --git a/src/app.swift b/src/app.swift
    index 1111111..2222222 100644
    --- a/src/app.swift
    +++ b/src/app.swift
    @@ -1,4 +1,5 @@ struct App {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     let d = 5
    -let e = 6
    \\ No newline at end of file
    diff --git a/new file.txt b/new file.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new file.txt\t
    @@ -0,0 +1 @@
    +hello
    diff --git a/old.txt b/renamed.txt
    similarity index 100%
    rename from old.txt
    rename to renamed.txt
    diff --git a/logo.png b/logo.png
    index 4444444..5555555 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    --- looks like a header but is content
    """

    func testParsesFiles() {
        let files = DiffParser.parse(Data(sample.utf8))
        XCTAssertEqual(files.map(\.path), ["src/app.swift", "new file.txt", "renamed.txt", "logo.png", "gone.txt"])
        XCTAssertEqual(files.map(\.status), [.modified, .added, .renamed, .modified, .deleted])

        let app = files[0]
        XCTAssertEqual(app.additions, 2)
        XCTAssertEqual(app.deletions, 2)
        let lines = app.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .addition, .context, .deletion, .noNewline])
        XCTAssertEqual(lines[2].newNumber, 2)
        XCTAssertEqual(lines[4].oldNumber, 3)
        XCTAssertEqual(lines[4].newNumber, 4)

        XCTAssertNil(files[1].oldPath)
        XCTAssertEqual(files[2].oldPath, "old.txt")
        XCTAssertTrue(files[2].hunks.isEmpty)
        XCTAssertTrue(files[3].isBinary)
        XCTAssertEqual(files[4].deletions, 1)
        XCTAssertEqual(files[4].hunks[0].lines[0].text, "-- looks like a header but is content")
    }

    func testSplitRowsPairChanges() {
        let rows = DiffParser.parse(Data(sample.utf8))[0].splitRows
        // hunk, ctx, (b2|b3), (nil|c4), ctx, (e6|nil), no-newline
        XCTAssertEqual(rows.count, 7)
        guard case .pair(let l, let r) = rows[2] else { return XCTFail() }
        XCTAssertEqual(l?.text, "let b = 2")
        XCTAssertEqual(r?.text, "let b = 3")
        guard case .pair(let l2, let r2) = rows[3] else { return XCTFail() }
        XCTAssertNil(l2)
        XCTAssertEqual(r2?.text, "let c = 4")
    }
}

final class GitIntegrationTests: XCTestCase {
    func testCompareBranches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func git(_ args: String...) throws { try Git.run(Array(args), in: dir) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try write("a.txt", "one\ntwo\n")
        try git("add", ".")
        try git("commit", "-qm", "initial")
        try git("checkout", "-qb", "feature")
        try write("a.txt", "one\nTWO\n")
        try write("b.txt", "new\n")
        try git("add", ".")
        try git("commit", "-qm", "feature work")
        // A commit on main after branching must not show up (three-dot semantics).
        try git("checkout", "-q", "main")
        try write("c.txt", "main only\n")
        try git("add", ".")
        try git("commit", "-qm", "main work")
        try git("checkout", "-q", "feature")
        try write("untracked.txt", "wip\n")

        let info = try Git.repositoryInfo(at: dir)
        XCTAssertEqual(info.currentBranch, "feature")
        XCTAssertEqual(info.defaultBase, "main")
        XCTAssertEqual(Set(info.branches), ["main", "feature"])

        let cmp = try Git.compare(repo: dir, base: "main", head: "feature", includeWorkingTree: false)
        XCTAssertEqual(cmp.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(cmp.commits.map(\.subject), ["feature work"])

        let wip = try Git.compare(repo: dir, base: "main", head: "feature", includeWorkingTree: true)
        XCTAssertEqual(wip.files.map(\.path), ["a.txt", "b.txt", "untracked.txt"])
        XCTAssertEqual(wip.files[2].status, .added)

        XCTAssertThrowsError(try Git.compare(repo: dir, base: "nope", head: "feature", includeWorkingTree: false))

        // Two commits on the same branch: same logic, commit hashes as refs.
        let history = try Git.history(repo: dir, ref: "feature")
        XCTAssertEqual(history.map(\.subject), ["feature work", "initial"])
        XCTAssertEqual(history[0].sha.count, 40)
        let range = try Git.compare(repo: dir, base: history[1].sha, head: history[0].sha, includeWorkingTree: false)
        XCTAssertEqual(range.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(range.commits.map(\.subject), ["feature work"])
        // Reversed (base newer than compare): nothing to show, like GitHub.
        let reversed = try Git.compare(repo: dir, base: history[0].sha, head: history[1].sha, includeWorkingTree: false)
        XCTAssertTrue(reversed.files.isEmpty)
    }
}
