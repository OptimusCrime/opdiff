import Foundation
import XCTest

@testable import DiffCore

final class NavigationTests: XCTestCase {
    func testWordDiffEmphasisesChangedWords() throws {
        let r = try XCTUnwrap(
            WordDiff.ranges(old: "let total = price * count", new: "let total = price * amount + tax"))
        XCTAssertEqual(r.old, [20..<25])  // "count"
        XCTAssertEqual(r.new, [20..<32])  // "amount + tax"
        // Completely different lines: no emphasis.
        XCTAssertNil(WordDiff.ranges(old: "import Foundation", new: "return value.map { $0 * 2 }"))
        XCTAssertNil(WordDiff.ranges(old: "same", new: "same"))
    }

    func testEmphasisPairsLinesInHunk() throws {
        let diff = """
            diff --git a/x.swift b/x.swift
            --- a/x.swift
            +++ b/x.swift
            @@ -1,3 +1,3 @@
             keep
            -\tfoo(a, b)
            +\tfoo(a, c)
             tail
            """
        let file = try XCTUnwrap(DiffParser.parse(Data(diff.utf8)).first)
        // Offsets are in the display text, where the tab is four spaces.
        XCTAssertEqual(file.oldEmphasis[2], [11..<12])
        XCTAssertEqual(file.newEmphasis[2], [11..<12])
    }

    func testSearchAndBlocks() throws {
        let diff = """
            diff --git a/x.swift b/x.swift
            --- a/x.swift
            +++ b/x.swift
            @@ -1,5 +1,5 @@
             Alpha alpha
            -beta
            +BETA alpha
             gamma
             delta
            @@ -10,2 +10,2 @@
            -old
            +new
            """
        let files = DiffParser.parse(Data(diff.utf8))
        let matches = DiffSearch.find("alpha", in: files)
        XCTAssertEqual(matches.map(\.range), [0..<5, 6..<11, 5..<10])
        XCTAssertEqual(matches[2].line, LineID(old: nil, new: 2))
        XCTAssertEqual(DiffSearch.find("alpha", in: files, limit: 2).count, 2)

        let rows = files[0].unifiedRows  // hunk, Alpha, -beta, +BETA, gamma, delta, hunk, -old, +new
        XCTAssertEqual(DiffNavigation.changeBlocks(rows), [2...3, 7...8])
        XCTAssertEqual(DiffNavigation.changeBlocks(files[0].splitRows), [2...2, 6...6])
        XCTAssertEqual(DiffNavigation.rowIndex(of: matches[2].line, in: rows), 3)
        XCTAssertEqual(DiffNavigation.editorLine(at: 2, in: rows), 2)  // deleted line → next new line
        XCTAssertEqual(DiffNavigation.editorLine(at: 5, in: rows), 4)
    }

    func testContextWhitespaceAndChangeHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: String...) throws { try Git.run(Array(args), in: dir) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let lines = (1...40).map { "line \($0)" }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try write("a.txt", lines.joined(separator: "\n") + "\n")
        try write("ws.txt", "x = 1\n")
        try git("add", ".")
        try git("commit", "-qm", "initial")
        try git("checkout", "-qb", "feature")
        var changed = lines
        changed[19] = "line 20 changed"
        try write("a.txt", changed.joined(separator: "\n") + "\n")
        try write("ws.txt", "x  =  1\n")
        try git("commit", "-qam", "change")

        let cmp = try Git.compare(repo: dir, base: "main", head: "feature", includeWorkingTree: false)
        XCTAssertEqual(cmp.files.map(\.path), ["a.txt", "ws.txt"])
        let noWS = try Git.compare(
            repo: dir, base: "main", head: "feature", includeWorkingTree: false,
            ignoreWhitespace: true)
        XCTAssertEqual(noWS.files.map(\.path), ["a.txt"])

        let a = cmp.files[0]
        XCTAssertEqual(a.lineCount, 8)  // 3 + 2 changed + 3
        let wider = try XCTUnwrap(
            Git.fileDiff(
                repo: dir, from: cmp.mergeBase!, to: "feature", path: "a.txt",
                oldPath: nil, context: 10))
        XCTAssertEqual(wider.lineCount, 22)
        let full = try XCTUnwrap(
            Git.fileDiff(
                repo: dir, from: cmp.mergeBase!, to: "feature", path: "a.txt",
                oldPath: nil, context: 1_000_000))
        XCTAssertEqual(full.lineCount, 41)
        XCTAssertEqual(full.changeHash, a.changeHash)  // same changes, more context
        XCTAssertNotEqual(full.contentHash, a.contentHash)

        XCTAssertEqual(Git.ignoredPaths(["a.txt"], in: dir), [])
        try write(".gitignore", "build/\n")
        XCTAssertEqual(Git.ignoredPaths(["build/out.o", "a.txt"], in: dir), ["build/out.o"])
    }

    func testParsesAnswers() throws {
        let structured =
            #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"structured_output":{"answer":"It **leaks**."}}"#
        XCTAssertEqual(try ClaudeOutput.parseAnswer(Data(structured.utf8)).answer, "It **leaks**.")
        let plain = #"{"type":"result","subtype":"success","is_error":false,"result":"Plain text answer"}"#
        XCTAssertEqual(try ClaudeOutput.parseAnswer(Data(plain.utf8)).answer, "Plain text answer")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(AnswerSchema.json.utf8)))

        let diff = """
            diff --git a/x.swift b/x.swift
            --- a/x.swift
            +++ b/x.swift
            @@ -1,2 +1,2 @@
             keep
            -old
            +new
            """
        let file = try XCTUnwrap(DiffParser.parse(Data(diff.utf8)).first)
        let context = ReviewContext(
            base: "main", head: "f", mergeBase: nil, includesWorkingTree: false,
            commitCount: 1, focus: "")
        let prompt = QuestionPrompt.build(
            file: file, selected: Array(file.hunks[0].lines[1...2]),
            question: "Why?", context: context)
        XCTAssertTrue(prompt.contains("    2       - old"))
        XCTAssertTrue(prompt.contains("# Question\n\nWhy?"))
        XCTAssertTrue(prompt.contains("FILE: x.swift"))
    }
}
