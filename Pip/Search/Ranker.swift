import Foundation

/// Scores a candidate: fixed weights over a few features.
@MainActor
final class Ranker {

    /// Weights before there's any evidence.
    static let priors: [Double] = [
        1.60,   // nameMatch       — naming a file is a strong statement of intent
        0.70,   // whereFromMatch  — "the pdf from arxiv", rare but decisive
        1.10,   // textMatch       — BM25, and worth more than the crude
                //                   word-overlap fraction it replaced: it
                //                   knows a rare word from a common one
        0.55,   // recency         — usually right, occasionally very wrong
        0.35,   // familiarity     — a file opened often is often wanted again
        0.45,   // typeMatch       — "pdf" in the query means something
        0.25,   // retrievalRank   — Spotlight's own opinion, worth a little
    ]

    // MARK: - Scoring

    func score(_ features: Features) -> Double {
        dot(features.vector, Self.priors)
    }

    func score(_ candidates: inout [Candidate]) {
        let w = Self.priors
        let total = w.reduce(0, +)
        let withoutText = total - w[Features.textIndex]

        for index in candidates.indices {
            let features = candidates[index].features
            var score = dot(features.vector, w)

            // An unread file is scored on the weight actually measured, so not being
            // read isn't a penalty.
            if !features.textWasMeasured, withoutText > 0 {
                score *= total / withoutText
            }
            candidates[index].score = score
        }
        candidates.sort { $0.score > $1.score }
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The weights, for the diagnostics.
    func explain() -> String {
        var lines = ["ranker weights"]
        let w = Self.priors
        for (index, name) in Features.names.enumerated() {
            let padded = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let bar = String(repeating: "█", count: max(0, Int(w[index] * 8)))
            lines.append("  \(padded) \(String(format: "%5.2f", w[index]))  \(bar)")
        }
        return lines.joined(separator: "\n")
    }
}
