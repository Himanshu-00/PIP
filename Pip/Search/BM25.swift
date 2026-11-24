import Foundation

/// BM25: lexical relevance with word rarity and document length.
struct BM25 {

    /// Saturation. Past a few occurrences, more of the same word stops being
    /// evidence — a word appearing twenty times usually means a long document,
    /// not a more relevant one.
    private static let k1 = 1.4
    /// How hard to penalise length. 0.75 is the value everyone uses because it
    /// works.
    private static let b = 0.75

    private let documentFrequency: [String: Int]
    private let documentCount: Int
    private let averageLength: Double

    /// IDF from the candidate set, not the whole disk.
    init(documents: [[String]]) {
        var frequency: [String: Int] = [:]
        var total = 0
        for words in documents {
            total += words.count
            for word in Set(words) { frequency[word, default: 0] += 1 }
        }
        documentFrequency = frequency
        documentCount = max(documents.count, 1)
        averageLength = documents.isEmpty ? 1 : Double(total) / Double(documents.count)
    }

    /// Raw BM25. Unbounded above, so callers normalise across the set.
    func score(query: [String], document: [String]) -> Double {
        guard !document.isEmpty, !query.isEmpty else { return 0 }

        var counts: [String: Int] = [:]
        for word in document { counts[word, default: 0] += 1 }
        let length = Double(document.count)

        var total = 0.0
        for term in Set(query) {
            guard let frequency = counts[term], frequency > 0 else { continue }
            let containing = Double(documentFrequency[term] ?? 0)
            // The +0.5s are smoothing; the max() stops a term present in every
            // document from contributing a negative score.
            let idf = max(0, log((Double(documentCount) - containing + 0.5)
                                 / (containing + 0.5) + 1))
            let tf = Double(frequency)
            let saturated = tf * (Self.k1 + 1)
                / (tf + Self.k1 * (1 - Self.b + Self.b * length / averageLength))
            total += idf * saturated
        }
        return total
    }

    /// Scales scores to 0…1 relative to the best, with an absolute floor.
    static func normalise(_ scores: [Double]) -> [Double] {
        guard let highest = scores.max(), highest > 0 else { return scores.map { _ in 0 } }
        let confidence = min(1, highest / 4.0)
        return scores.map { ($0 / highest) * confidence }
    }

    /// FTS5 scores: relative to the best hit, capped below 1 (their magnitude
    /// grows with corpus size).
    static func normaliseExternal(_ scores: [Double], ceiling: Double = 0.85) -> [Double] {
        guard let highest = scores.max(), highest > 0 else { return scores.map { _ in 0 } }
        return scores.map { ($0 / highest) * ceiling }
    }
}
