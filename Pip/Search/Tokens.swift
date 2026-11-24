import Foundation

/// The one place text becomes words, for queries and documents alike.
enum Tokens {

    /// A deliberately short stoplist.
    private static let stop: Set<String> = [
        "the", "a", "an", "my", "that", "this", "from",
        "about", "for", "of", "in", "on", "with", "and",
    ]

    /// Lowercased alphanumeric runs, minus the words that match everything.
    static func of(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter(isUseful)
    }

    /// Query words, with shorthand spelled out: "attn is all you need" asks
    /// for "attention", which is the word the paper actually contains. For
    /// queries only — documents are tokenised with `of`.
    static func query(_ text: String) -> [String] {
        of(text).map { stem(abbreviations[$0] ?? kindTypo($0) ?? $0) }
    }

    /// Misspelt kind words ("picturrw"), one slip in 5–7 letters, two above.
    private static let kindWords = Array(QueryParse.kinds.keys.filter { $0.count >= 5 })

    private static func kindTypo(_ word: String) -> String? {
        guard word.count >= 5, !word.contains(where: \.isNumber), QueryParse.extensions(for: word) == nil else { return nil }
        let allowed = word.count >= 8 ? 2 : 1
        return kindWords.first { abs($0.count - word.count) <= allowed && editDistance(word, $0, limit: allowed) <= allowed }
    }

    /// Levenshtein distance, giving up past `limit`.
    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0 ... b.count)
        for i in 1 ... a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1 ... b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    /// A crude stem for queries ("augmented" → "augment"), always matched as a
    /// prefix. Short words and anything with a digit stay.
    static func stem(_ word: String) -> String {
        guard !word.contains(where: \.isNumber) else { return word }
        if word.count >= 7, word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count >= 6, word.hasSuffix("ed"), !word.hasSuffix("eed") { return String(word.dropLast(2)) }
        if word.count >= 5, word.hasSuffix("s"),
           !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    /// The query as text with shorthand spelled out, for the meaning model,
    /// which reads sentences rather than word lists.
    static func expandText(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            let word = String(piece)
            return abbreviations[word.lowercased()] ?? word
        }.joined(separator: " ")
    }

    /// Common shorthand → the word documents use.
    static let abbreviations: [String: String] = [
        "attn": "attention", "info": "information", "docs": "documents", "pres": "presentation",
        "presi": "presentation", "assgn": "assignment", "asgn": "assignment", "assign": "assignment",
        "uni": "university", "univ": "university", "govt": "government", "dept": "department",
        "mgmt": "management", "req": "requirements", "reqs": "requirements", "ref": "reference",
        "refs": "references", "intro": "introduction", "lec": "lecture", "lect": "lecture",
        "tut": "tutorial", "eval": "evaluation", "exp": "experiment", "impl": "implementation",
        "config": "configuration", "spec": "specification", "acct": "account", "stmt": "statement",
        "inv": "invoice", "rcpt": "receipt", "appt": "appointment", "cert": "certificate",
        "transcr": "transcript", "nn": "neural", "rl": "reinforcement", "cnn": "convolutional",
    ]

    private static func isUseful(_ word: String) -> Bool {
        guard !word.isEmpty, !stop.contains(word) else { return false }
        // A lone digit is a word; a lone letter isn't.
        if word.count == 1 { return word.first?.isNumber == true }
        return true
    }
}
