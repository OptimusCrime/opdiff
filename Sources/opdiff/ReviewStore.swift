import CryptoKit
import DiffCore
import Foundation

/// Saved reviews and questions, one JSON file per comparison in Application Support.
enum ReviewStore {
    private static func reviewURL(key: String, folder: String = "reviews") -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appendingPathComponent("OptimusDiff/\(folder)", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    static func loadQuestions(key: String) -> [Annotation] {
        guard let data = try? Data(contentsOf: reviewURL(key: key, folder: "questions")) else { return [] }
        return (try? JSONDecoder().decode([Annotation].self, from: data)) ?? []
    }

    static func saveQuestions(_ questions: [Annotation], key: String) {
        let url = reviewURL(key: key, folder: "questions")
        if questions.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(questions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func loadReview(key: String) -> CompareModel.StoredReview? {
        guard let data = try? Data(contentsOf: reviewURL(key: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompareModel.StoredReview.self, from: data)
    }

    static func saveReview(_ review: CompareModel.StoredReview, key: String) {
        let url = reviewURL(key: key)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(review) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func deleteReview(key: String) {
        try? FileManager.default.removeItem(at: reviewURL(key: key))
    }
}
