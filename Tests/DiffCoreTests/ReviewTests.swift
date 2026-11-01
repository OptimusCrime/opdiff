import Foundation
import XCTest
@testable import DiffCore

final class ReviewTests: XCTestCase {
    let reviewJSON = """
    {"summary":"Adds b.","annotations":[
      {"file":"src/app.swift","side":"new","startLine":3,"endLine":2,"kind":"important","comment":"Check this."}
    ]}
    """

    func testParsesEventArrayWithStructuredOutput() throws {
        let output = """
        [{"type":"system","subtype":"init"},
         {"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.12,
          "result":"ignored","structured_output":\(reviewJSON)}]
        """
        let result = try ClaudeOutput.parse(Data(output.utf8))
        XCTAssertEqual(result.review.summary, "Adds b.")
        XCTAssertEqual(result.costUSD, 0.12)
        let a = try XCTUnwrap(result.review.annotations.first)
        XCTAssertEqual(a.kind, .important)
        // start/end are normalised
        XCTAssertEqual(a.startLine, 2)
        XCTAssertEqual(a.endLine, 3)
    }

    func testParsesSingleObjectWithFencedResultAndShellNoise() throws {
        let escaped = String(data: try JSONSerialization.data(withJSONObject: ["```json\n" + reviewJSON + "\n```"]), encoding: .utf8)!
        let resultString = String(escaped.dropFirst().dropLast())  // the JSON string literal
        let output = """
        Welcome to zsh!
        {"type":"result","subtype":"success","is_error":false,"result":\(resultString)}
        """
        let result = try ClaudeOutput.parse(Data(output.utf8))
        XCTAssertEqual(result.review.annotations.count, 1)
    }

    func testReportsClaudeErrors() {
        let output = #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":""}"#
        XCTAssertThrowsError(try ClaudeOutput.parse(Data(output.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("error_max_turns"))
        }
        XCTAssertThrowsError(try ClaudeOutput.parse(Data("command not found: pclaude".utf8)))
    }

    func testLayoutPlacesCardsOnLastVisibleLine() throws {
        let diff = """
        diff --git a/src/app.swift b/src/app.swift
        --- a/src/app.swift
        +++ b/src/app.swift
        @@ -1,4 +1,5 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        """
        let file = try XCTUnwrap(DiffParser.parse(Data(diff.utf8)).first)
        let annotations = [
            Annotation(file: file.path, side: .new, startLine: 2, endLine: 3, kind: .attention, comment: "new"),
            Annotation(file: file.path, side: .new, startLine: 3, endLine: 9, kind: .important, comment: "clamped"),
            Annotation(file: file.path, side: .old, startLine: 2, endLine: 2, kind: .info, comment: "deleted"),
            Annotation(file: file.path, side: .new, startLine: 40, endLine: 41, kind: .info, comment: "outside"),
        ]
        let layout = AnnotationLayout(file: file, annotations: annotations)
        let lines = file.hunks[0].lines  // ctx a, -b, +b, +c, ctx d

        XCTAssertEqual(layout.marker(for: lines[1]), .info)        // deleted line, old side
        XCTAssertEqual(layout.marker(for: lines[2]), .attention)   // new line 2
        XCTAssertEqual(layout.marker(for: lines[3]), .important)   // new line 3: strongest wins
        XCTAssertEqual(layout.cards(after: lines[1]).map(\.comment), ["deleted"])
        XCTAssertEqual(layout.cards(after: lines[3]).map(\.comment), ["new"])
        // Range 3–9 is clamped to the last visible line (new 4 = "let d")
        XCTAssertEqual(layout.cards(after: lines[4]).map(\.comment), ["clamped"])
        XCTAssertEqual(layout.unplaced.map(\.comment), ["outside"])
    }

    func testPromptShowsLineNumbersAndFocus() throws {
        let diff = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -10,2 +10,2 @@
         keep
        -old
        +new
        """
        let files = DiffParser.parse(Data(diff.utf8))
        let context = ReviewContext(base: "main", head: "feature", mergeBase: "abc123", includesWorkingTree: false,
                                    commitCount: 1, focus: "error handling")
        let prompt = ReviewPrompt.build(files: files, context: context)
        XCTAssertTrue(prompt.contains("FILE: x.swift"))
        XCTAssertTrue(prompt.contains("   10    10   keep"))
        XCTAssertTrue(prompt.contains("   11       - old"))
        XCTAssertTrue(prompt.contains("         11 + new"))
        XCTAssertTrue(prompt.contains("focus on: error handling"))
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(ReviewSchema.json.utf8)))
    }

    func testCancelStopsTheRunningCommand() throws {
        // A random duration identifies our process; "#" turns the appended claude arguments into a comment.
        let duration = String(format: "%.3f", Double.random(in: 40...90))
        let run = ClaudeReviewRun(command: "sleep \(duration) #", directory: FileManager.default.temporaryDirectory,
                                  prompt: "hello")
        let finished = expectation(description: "run returns after cancel")
        let started = Date()
        var thrown: Error?
        DispatchQueue.global().async {
            do { _ = try run.run() } catch { thrown = error }
            finished.fulfill()
        }
        // Give the login shell time to start, then cancel.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { run.cancel() }
        wait(for: [finished], timeout: 15)
        XCTAssertTrue(thrown is CancellationError, "expected CancellationError, got \(String(describing: thrown))")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        // Nothing left running.
        let check = Process()
        let out = Pipe()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-axo", "pid,ppid,pgid,stat,command"]
        check.standardOutput = out
        try check.run()
        let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check.waitUntilExit()
        let leftovers = listing.split(separator: "\n").filter { $0.contains("sleep \(duration)") }
        XCTAssertTrue(leftovers.isEmpty, "still running:\n" + leftovers.joined(separator: "\n"))
    }

    func testResolvesAnnotationPathsAndRows() throws {
        let diff = """
        diff --git a/old/name.swift b/src/name.swift
        similarity index 90%
        rename from old/name.swift
        rename to src/name.swift
        --- a/old/name.swift
        +++ b/src/name.swift
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        diff --git a/src/other.swift b/src/other.swift
        --- a/src/other.swift
        +++ b/src/other.swift
        @@ -1 +1 @@
        -a
        +b
        """
        let files = DiffParser.parse(Data(diff.utf8))
        XCTAssertEqual(AnnotationFileResolver.resolve("src/name.swift", in: files)?.path, "src/name.swift")
        XCTAssertEqual(AnnotationFileResolver.resolve("old/name.swift", in: files)?.path, "src/name.swift")
        XCTAssertEqual(AnnotationFileResolver.resolve("./src/other.swift", in: files)?.path, "src/other.swift")
        XCTAssertEqual(AnnotationFileResolver.resolve("b/src/other.swift", in: files)?.path, "src/other.swift")
        XCTAssertEqual(AnnotationFileResolver.resolve("/Users/me/repo/src/other.swift", in: files)?.path, "src/other.swift")
        XCTAssertNil(AnnotationFileResolver.resolve("missing.swift", in: files))

        let file = files[0]
        let onNew = Annotation(file: file.path, side: .new, startLine: 2, endLine: 2, kind: .info, comment: "n")
        let onOld = Annotation(file: file.path, side: .old, startLine: 2, endLine: 2, kind: .info, comment: "o")
        let layout = AnnotationLayout(file: file, annotations: [onNew, onOld])
        // unified: hunk, ctx, -old, +new
        XCTAssertEqual(layout.rowIndex(of: onNew, in: file.unifiedRows), 3)
        XCTAssertEqual(layout.rowIndex(of: onOld, in: file.unifiedRows), 2)
        // split: hunk, (ctx|ctx), (old|new)
        XCTAssertEqual(layout.rowIndex(of: onNew, in: file.splitRows), 2)
        XCTAssertEqual(layout.rowIndex(of: onOld, in: file.splitRows), 2)
    }
}
