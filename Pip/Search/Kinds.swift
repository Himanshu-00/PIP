import Foundation

/// The kind a file is filed under ("research paper", "rent receipt"), kept
/// in the content store (`documents.kind`) so a search for a kind goes
/// straight to its group. No list of kinds: Pip's brain names them when it
/// describes a file (`DocumentNotes`), and a query's kind is read from the
/// query the same way.
enum Kinds {

    /// One spelling for a kind: lowercase words without accents, each
    /// stemmed, at most three ("Research papers" → "research paper"), and a
    /// second spelling merged ("CV" → "resume").
    static func normalise(_ phrase: String) -> String? {
        // "Résumé" and "resume" are one kind.
        let folded = phrase.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = Tokens.of(folded)
            .filter { $0.count >= 2 && !$0.contains(where: \.isNumber) }
            .suffix(3)
            .map(singular)
        guard !words.isEmpty else { return nil }
        let kind = words.joined(separator: " ")
        return variants[kind] ?? kind
    }

    /// "papers" → "paper", and nothing else: a stem would cut "setting" to
    /// "sett" (and again each time it ran), so kinds are only made singular.
    static func singular(_ word: String) -> String {
        guard word.count >= 5, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"),
              !word.hasSuffix("is") else { return word }
        return String(word.dropLast())
    }

    /// A kind whose words were cut by the old stemming ("configuration
    /// sett", "train data"), made whole again from the description's own
    /// words ("Configuration settings for…" → "configuration setting").
    static func repaired(_ kind: String, from about: String) -> String {
        let said = Tokens.of(about.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
        return kind.split(separator: " ").map { part -> String in
            let word = String(part)
            // Said as it is: that was the word ("Build script for building…").
            guard !said.contains(word), !said.contains(word + "s") else { return word }
            let whole = said.filter { $0.count > word.count && $0.hasPrefix(word) }
                .filter { ["ing", "ings", "ed"].contains(String($0.dropFirst(word.count)))
                          || ["ing", "ings", "ed"].contains(String($0.dropFirst(word.count + 1))) && $0.dropFirst(word.count).first == word.last }
                .min { $0.count < $1.count }
            return whole.map(singular) ?? word
        }.joined(separator: " ")
    }

    /// Other spellings of the same kind — not a list of kinds: Pip names
    /// those; this only merges what he spells two ways.
    private static let variants: [String: String] = [
        "cv": "resume", "curriculum vita": "resume", "curriculum vitae": "resume",
    ]

    /// The last word of a kind: what kind of thing it is ("paper").
    static func head(_ kind: String) -> String {
        kind.split(separator: " ").last.map(String.init) ?? kind
    }

    /// A kind read from a description written before kinds were stored:
    /// the words before its first "on", "for"… and at most the two that end
    /// there ("Draft anime tourism research paper" → "research paper").
    static func fromLine(_ about: String) -> String? {
        guard let kind = ResultGroups.kind(of: about) else { return nil }
        return normalise(kind.phrase.split(separator: " ").suffix(2).joined(separator: " "))
    }

    /// Words a request wraps around the kind: who's asking, how many.
    private static let asking: Set<String> = QueryParse.chatWords.union([
        "all", "every", "each", "list", "my", "the", "a", "an", "you", "i", "is", "are", "of", "some", "any", "please",
    ])

    /// The kind a search asks for ("can you list all research papers on my
    /// mac" → "research paper"; "slides on autoencoders" → "slide"), or nil.
    /// A format ("pdf about …") is a filter, not a kind.
    static func asked(in query: String) -> String? {
        guard let kind = ResultGroups.kind(of: query) else { return nil }
        // Numbers out before the last two are taken: "sem 3 result" is a
        // "sem result", not any "result".
        let words = Tokens.of(kind.phrase).filter { !asking.contains($0) && !$0.contains(where: \.isNumber) }
        guard let normal = normalise(words.suffix(2).joined(separator: " ")),
              QueryParse.extensions(for: head(normal)) == nil else { return nil }
        return normal
    }

    /// How well a file's kind answers the one asked for: 2 the same kind
    /// ("research paper"), 1 the same thing ("exam paper" for "research
    /// paper", any paper for "papers"), 0 another kind, nil not filed yet.
    static func match(_ kind: String?, asked: String) -> Int? {
        guard let kind, !kind.isEmpty else { return nil }
        if kind == asked { return 2 }
        return head(kind) == head(asked) ? 1 : 0
    }
}
