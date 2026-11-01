import Foundation

// MARK: - Review format (what Claude returns)

public enum AnnotationKind: String, Codable, Sendable, CaseIterable, Comparable {
    case important, attention, info
    /// The user's own question about some lines, answered by Claude (not part of the review schema).
    case question

    /// Higher wins when several annotations cover the same line.
    public var rank: Int {
        switch self {
        case .important: 3
        case .attention: 2
        case .info: 1
        case .question: 0
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum AnnotationSide: String, Codable, Sendable {
    case new, old
}

public struct Annotation: Codable, Sendable, Hashable, Identifiable {
    public var file: String
    public var side: AnnotationSide
    public var startLine: Int
    public var endLine: Int
    public var kind: AnnotationKind
    public var comment: String
    /// For `.question`: what the user asked (`comment` holds Claude's answer).
    public var question: String?
    /// Stable id for user questions, whose answer (and so the content) changes.
    public var uid: String?

    public var id: String {
        uid ?? "\(file):\(side.rawValue):\(startLine)-\(endLine):\(kind.rawValue):\(comment)"
    }

    public init(file: String, side: AnnotationSide, startLine: Int, endLine: Int,
                kind: AnnotationKind, comment: String, question: String? = nil, uid: String? = nil) {
        self.file = file
        self.side = side
        self.startLine = min(startLine, endLine)
        self.endLine = max(startLine, endLine)
        self.kind = kind
        self.comment = comment
        self.question = question
        self.uid = uid
    }

    public var lineLabel: String {
        startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
    }
}

public struct Review: Codable, Sendable {
    public var summary: String
    public var annotations: [Annotation]

    public init(summary: String, annotations: [Annotation]) {
        self.summary = summary
        self.annotations = annotations
    }
}

public enum ReviewSchema {
    /// JSON Schema passed to `claude --json-schema`; the CLI validates the reply against it.
    public static let json = """
    {"type":"object","additionalProperties":false,"required":["summary","annotations"],\
    "properties":{"summary":{"type":"string"},"annotations":{"type":"array","items":{\
    "type":"object","additionalProperties":false,\
    "required":["file","side","startLine","endLine","kind","comment"],\
    "properties":{"file":{"type":"string"},"side":{"type":"string","enum":["new","old"]},\
    "startLine":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1},\
    "kind":{"type":"string","enum":["important","attention","info"]},\
    "comment":{"type":"string"}}}}}}
    """
}

// MARK: - Parsing `claude -p --output-format json`

public struct ClaudeResult: Sendable {
    public let review: Review
    public let costUSD: Double?
}

public struct ClaudeAnswer: Sendable {
    public let answer: String
    public let costUSD: Double?
}

/// Schema for answers to "Ask Claude about these lines".
public enum AnswerSchema {
    public static let json = #"{"type":"object","additionalProperties":false,"required":["answer"],"properties":{"answer":{"type":"string"}}}"#
}

public enum ClaudeOutput {
    /// Accepts either a single result object or an array of events (newer CLI versions),
    /// and tolerates shell start-up noise around the JSON.
    public static func parse(_ data: Data) throws -> ClaudeResult {
        let (reviewData, cost) = try structuredOutput(data)
        let decoded: Review
        do { decoded = try JSONDecoder().decode(Review.self, from: reviewData) } catch {
            throw GitError(message: "Claude's reply didn't match the review format: \(error.localizedDescription)")
        }
        // Re-create annotations so start/end are normalised.
        var seen = Set<String>()
        let annotations = decoded.annotations
            .map { Annotation(file: $0.file, side: $0.side, startLine: $0.startLine, endLine: $0.endLine,
                              kind: $0.kind, comment: $0.comment) }
            .filter { seen.insert($0.id).inserted }  // identical duplicates would share an id
        return ClaudeResult(review: Review(summary: decoded.summary, annotations: annotations), costUSD: cost)
    }

    /// The answer to a question; falls back to the plain text if Claude didn't use the schema.
    public static func parseAnswer(_ data: Data) throws -> ClaudeAnswer {
        let (answerData, cost) = try structuredOutput(data)
        struct Answer: Decodable { let answer: String }
        if let decoded = try? JSONDecoder().decode(Answer.self, from: answerData) {
            return ClaudeAnswer(answer: decoded.answer, costUSD: cost)
        }
        let text = String(decoding: answerData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GitError(message: "Claude returned an empty answer.") }
        return ClaudeAnswer(answer: text, costUSD: cost)
    }

    /// The JSON Claude produced for the schema, and the run's cost.
    static func structuredOutput(_ data: Data) throws -> (Data, Double?) {
        guard let result = findResultEvent(data) else {
            let text = String(decoding: data.prefix(600), as: UTF8.self)
            throw GitError(message: "Couldn't find Claude's result in its output.\n\(text)")
        }
        let isError = result["is_error"] as? Bool ?? false
        let subtype = result["subtype"] as? String ?? "success"
        guard !isError, subtype == "success" else {
            let message = (result["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? subtype
            throw GitError(message: "Claude reported an error: \(message)")
        }

        let cost = result["total_cost_usd"] as? Double
        if let structured = result["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            return (try JSONSerialization.data(withJSONObject: structured), cost)
        } else if let text = result["result"] as? String {
            return (Data(stripCodeFence(text).utf8), cost)
        }
        throw GitError(message: "Claude's reply had no structured output.")
    }

    private static func findResultEvent(_ data: Data) -> [String: Any]? {
        func result(in json: Any) -> [String: Any]? {
            if let dict = json as? [String: Any], dict["type"] as? String == "result" { return dict }
            if let array = json as? [Any] {
                return array.reversed().compactMap { $0 as? [String: Any] }.first { $0["type"] as? String == "result" }
            }
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: data), let r = result(in: json) { return r }
        // Noise before/after the JSON: try each line, then from the first '[' or '{'.
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)), let r = result(in: json) { return r }
        }
        for opener in ["[{", "{\""] {
            if let start = text.range(of: opener)?.lowerBound,
               let json = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)),
               let r = result(in: json) { return r }
        }
        return nil
    }

    static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstNewline)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t
    }
}

// MARK: - Placing annotations on diff lines

/// Where a file's annotations go in the diff view.
public struct AnnotationLayout: Sendable {
    /// Strongest annotation kind covering each visible line.
    public private(set) var markers: [AnnotationSide: [Int: AnnotationKind]] = [:]
    /// Cards shown under a line (the last visible line of each annotation's range).
    public private(set) var cards: [AnnotationSide: [Int: [Annotation]]] = [:]
    /// Annotations whose lines aren't in the diff; shown at the top of the file.
    public private(set) var unplaced: [Annotation] = []
    /// The line each placed annotation's card sits under, by annotation id.
    public private(set) var anchors: [String: Anchor] = [:]

    public struct Anchor: Sendable, Hashable {
        public let side: AnnotationSide
        public let line: Int
    }

    public var isEmpty: Bool { cards.isEmpty && unplaced.isEmpty }

    public init(file: FileDiff, annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        var visible: [AnnotationSide: Set<Int>] = [.new: [], .old: []]
        for line in file.hunks.flatMap(\.lines) {
            if line.kind != .deletion, let n = line.newNumber { visible[.new]!.insert(n) }
            if line.kind != .addition, let n = line.oldNumber { visible[.old]!.insert(n) }
        }
        for annotation in annotations {
            let shown = (annotation.startLine...annotation.endLine).filter { visible[annotation.side]!.contains($0) }
            guard let anchor = shown.last else {
                unplaced.append(annotation)
                continue
            }
            cards[annotation.side, default: [:]][anchor, default: []].append(annotation)
            anchors[annotation.id] = Anchor(side: annotation.side, line: anchor)
            for n in shown {
                let current = markers[annotation.side]?[n]
                if current == nil || current! < annotation.kind {
                    markers[annotation.side, default: [:]][n] = annotation.kind
                }
            }
        }
    }

    /// Marker for a diff line: deletions use the old side, everything else the new side
    /// (context lines also pick up old-side annotations).
    public func marker(for line: DiffLine) -> AnnotationKind? {
        var kinds: [AnnotationKind] = []
        if line.kind != .deletion, let n = line.newNumber, let k = markers[.new]?[n] { kinds.append(k) }
        if line.kind != .addition, let n = line.oldNumber, let k = markers[.old]?[n] { kinds.append(k) }
        return kinds.max()
    }

    /// Index of the row (in `rows`) that shows the annotation's card, for scrolling to it.
    public func rowIndex(of annotation: Annotation, in rows: [DiffRow]) -> Int? {
        guard let anchor = anchors[annotation.id] else { return nil }
        func matches(_ line: DiffLine?) -> Bool {
            guard let line else { return false }
            switch anchor.side {
            case .new: return line.kind != .deletion && line.newNumber == anchor.line
            case .old: return line.kind != .addition && line.oldNumber == anchor.line
            }
        }
        return rows.firstIndex { row in
            switch row {
            case .hunk: false
            case .line(let line): matches(line)
            case .pair(let old, let new): matches(old) || matches(new)
            }
        }
    }

    public func cards(after line: DiffLine) -> [Annotation] {
        var result: [Annotation] = []
        if line.kind != .addition, let n = line.oldNumber { result += cards[.old]?[n] ?? [] }
        if line.kind != .deletion, let n = line.newNumber { result += cards[.new]?[n] ?? [] }
        return result
    }
}

// MARK: - Matching annotation paths to files

public enum AnnotationFileResolver {
    /// The file an annotation refers to. Tries the exact path, the old path of renamed
    /// files, a normalised path ("./x", "a/x", "/abs/repo/x"), then a unique suffix match.
    public static func resolve(_ path: String, in files: [FileDiff]) -> FileDiff? {
        if let file = files.first(where: { $0.path == path || $0.oldPath == path }) { return file }
        let normalized = normalize(path)
        if let file = files.first(where: { $0.path == normalized || $0.oldPath == normalized }) { return file }
        let suffix = files.filter {
            $0.path.hasSuffix("/" + normalized) || normalized.hasSuffix("/" + $0.path)
        }
        return suffix.count == 1 ? suffix[0] : nil
    }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count >= 2, p.hasPrefix("`"), p.hasSuffix("`") { p = String(p.dropFirst().dropLast()) }
        while p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
