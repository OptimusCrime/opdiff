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

    public init(
        file: String, side: AnnotationSide, startLine: Int, endLine: Int,
        kind: AnnotationKind, comment: String, question: String? = nil, uid: String? = nil
    ) {
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
