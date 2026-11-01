import Foundation

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
    public static let json =
        #"{"type":"object","additionalProperties":false,"required":["answer"],"properties":{"answer":{"type":"string"}}}"#
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
            .map {
                Annotation(
                    file: $0.file, side: $0.side, startLine: $0.startLine, endLine: $0.endLine,
                    kind: $0.kind, comment: $0.comment)
            }
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
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)), let r = result(in: json) {
                return r
            }
        }
        for opener in ["[{", "{\""] {
            if let start = text.range(of: opener)?.lowerBound,
                let json = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)),
                let r = result(in: json)
            {
                return r
            }
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
