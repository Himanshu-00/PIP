import Foundation

/// Matching a half-remembered name ("attension", "q3 reprot", initials).
enum Fuzzy {

    /// Fraction of query words appearing literally (body text: no fuzziness).
    static func literalOverlap(_ words: [String], in text: String) -> Double {
        guard !words.isEmpty, !text.isEmpty else { return 0 }
        let haystack = text.lowercased()
        return Double(words.filter { haystack.contains($0) }.count) / Double(words.count)
    }

    /// Best of four strategies, 0…1.
    static func score(_ query: String, against name: String) -> Double {
        let haystack = normalise(name)
        let needle = normalise(query)
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }

        // 1. Contained, more if at the start. One or two characters must match a
        //    whole word ("3" isn't inside "2506.06941v3").
        if needle.count <= 2, !needle.contains(" ") {
            return haystack.split(separator: " ").contains(Substring(needle)) ? 0.92 : 0
        }

        // Three letters: a whole word, a word start or initials, never inside one.
        if needle.count == 3, !needle.contains(" ") {
            let words = haystack.split(separator: " ")
            if words.contains(Substring(needle)) { return 0.92 }
            if words.contains(where: { $0.hasPrefix(needle) }) { return 0.85 }
            return acronymScore(needle, haystack) ?? 0
        }

        // At a word start it counts; inside a word ("rent" in "parents") it doesn't.
        if haystack.contains(needle) {
            if haystack.hasPrefix(needle) { return 1.0 }
            if haystack.contains(" " + needle) { return 0.92 }
            return 0.55
        }

        // 2. Contained with separators removed ("img764" → IMG_7647), from a word start.
        let pieces = haystack.split(separator: " ")
        let flatNeedle = needle.replacingOccurrences(of: " ", with: "")
        for start in pieces.indices where pieces[start...].joined().hasPrefix(flatNeedle) {
            return start == pieces.startIndex ? 0.97 : 0.9
        }

        // Too short to guess about. Two letters match half the disk by
        // accident, and the strategies below are all inference.
        guard needle.count >= 3 else { return 0 }

        // 3. Initials. "aiayn" against "attention is all you need" — this is
        //    how people remember long titles, and nothing else catches it.
        if let acronym = acronymScore(needle, haystack), acronym > 0 {
            return acronym
        }

        // 4. Letters in order, gaps allowed: the tolerant one, which catches
        //    both typos and abbreviations at the cost of occasional nonsense.
        return subsequenceScore(needle, haystack)
    }

    /// Lowercase words: punctuation and camelCase become spaces; letters and
    /// digits aren't split.
    private static func normalise(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if let previous, !out.hasSuffix(" "), previous.isLowercase, character.isUppercase {
                    out.append(" ")
                }
                out.append(contentsOf: character.lowercased())
            } else if !out.hasSuffix(" ") {
                out.append(" ")
            }
            previous = character
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func acronymScore(_ needle: String, _ haystack: String) -> Double? {
        // Only worth trying for short queries: three or four letters is an
        // acronym, twelve is a sentence someone mistyped.
        guard needle.count >= 2, needle.count <= 6, !needle.contains(" ") else { return nil }
        let initials = haystack.split(separator: " ").compactMap(\.first)
        guard initials.count >= needle.count else { return nil }

        let joined = String(initials)
        if joined.hasPrefix(needle) { return 0.88 }
        if joined.contains(needle) { return 0.8 }
        return nil
    }

    /// Every letter in order, scored on how tight the run is.
    private static func subsequenceScore(_ needle: String, _ haystack: String) -> Double {
        let target = Array(haystack)
        let pattern = Array(needle.replacingOccurrences(of: " ", with: ""))
        guard !pattern.isEmpty, target.count >= pattern.count else { return 0 }

        var index = 0
        var matched = 0
        var runs = 0
        var wasConsecutive = false
        var firstHit: Int?

        for character in target {
            guard index < pattern.count else { break }
            if character == pattern[index] {
                if firstHit == nil { firstHit = matched }
                if wasConsecutive { runs += 1 }
                wasConsecutive = true
                index += 1
                matched += 1
            } else {
                wasConsecutive = false
            }
        }
        guard index == pattern.count else { return 0 }

        // Density of consecutive runs, mildly penalised for starting late in
        // the name.
        let tightness = Double(runs) / Double(max(pattern.count - 1, 1))
        let lateness = Double(firstHit ?? 0) / Double(target.count)

        // Under 75% consecutive is a coincidence, not a match.
        guard tightness >= 0.75 else { return 0 }
        return max(0, min(0.62, 0.1 + 0.5 * tightness - 0.15 * lateness))
    }

    /// Averaged across words, so matching both beats matching either.
    static func score(words: [String], against name: String) -> Double {
        guard !words.isEmpty else { return 0 }

        let scores = words.map { score($0, against: name) }
        let weights = words.map(weight)
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return 0 }

        let mean = zip(scores, weights).reduce(0) { $0 + $1.0 * $1.1 } / totalWeight

        // Half credit for the best single hit, from an identifying word only.
        let identifying = zip(scores, words)
            .filter { weight($0.1) >= 1 }
            .map(\.0)
            .max() ?? 0

        return max(mean, identifying * 0.5)
    }

    /// How much a word narrows things down, by length.
    private static func weight(_ word: String) -> Double {
        switch word.count {
        case 1:  return 0.25
        case 2:  return 0.5
        default: return 1
        }
    }
}
