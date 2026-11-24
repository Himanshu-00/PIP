import Foundation

/// The kind a file is filed under ("research paper", "rent receipt"), kept
/// in the content store (`documents.kind`) so a search for a kind goes
/// straight to its group. No list of kinds: Pip's brain names them when it
/// describes a file (`DocumentNotes`), and a query's kind is read from the
/// query the same way.
enum Kinds {

    /// One spelling for a kind: lowercase words, each stemmed, at most three
    /// ("Research papers" → "research paper").
    static func normalise(_ phrase: String) -> String? {
        let words = Tokens.of(phrase)
            .filter { $0.count >= 2 && !$0.contains(where: \.isNumber) }
            .suffix(3)
            .map(Tokens.stem)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

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
