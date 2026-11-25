import Foundation
import NaturalLanguage

/// Search results grouped by the kind each file is filed under in the
/// store (`documents.kind`, Pip's own words: "research paper", "receipt").
/// Only real groups: two files of a kind at least, and two kinds at least —
/// otherwise the plain list. No groups by likeness ("Like Screenshot…").
enum ResultGroups {

    struct Group: Sendable {
        var name: String
        var urls: [URL]
        /// A kind's group (not "Other").
        var named: Bool = false
    }

    /// Groups `urls` (in their ranked order) by kind; nil when fewer than
    /// `minGroups` kinds have two files. Each group, "Other" too, sits where
    /// its best file ranked, so the first result stays first.
    static func group(_ urls: [URL], query: String, minGroups: Int = 2) async -> [Group]? {
        guard urls.count >= 3 else { return nil }
        let notes = await ContentStore.shared.notes(for: urls.map(\.path))
        var byKind: [String: [Int]] = [:]
        for (index, url) in urls.enumerated() {
            guard let kind = notes[url.path]?.kind else { continue }
            byKind[kind, default: []].append(index)
        }
        let kinds = byKind.filter { $0.value.count >= 2 }
        guard kinds.count >= max(1, minGroups) else { return nil }
        var groups = kinds.map { Group(name: plural($0.key), urls: $0.value.map { urls[$0] }, named: true) }
        let grouped = Set(kinds.values.flatMap { $0 })
        let rest = urls.indices.filter { !grouped.contains($0) }.map { urls[$0] }
        if !rest.isEmpty { groups.append(Group(name: "Other", urls: rest)) }
        let rank = Dictionary(urls.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.sorted { (rank[$0.urls[0]] ?? 0) < (rank[$1.urls[0]] ?? 0) }
    }

    /// "research paper" → "Research papers" (Foundation's inflection).
    static func plural(_ kind: String) -> String {
        let many = String(AttributedString(localized: "^[\(2) \(kind)](inflect: true)").characters)
            .replacingOccurrences(of: #"^2 "#, with: "", options: .regularExpression)
        return many.prefix(1).uppercased() + many.dropFirst()
    }

    /// The kind in a description: the words before its first "on", "for",
    /// "and"… (English grammar, no list of kinds), and the last of them —
    /// the head of the phrase ("tourism assignment draft" → draft).
    static func kind(of about: String) -> (phrase: String, head: String)? {
        let lead = "it is a "
        let text = lead + about.lowercased().replacingOccurrences(of: "'s ", with: " ")
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [String] = []
        tagger.enumerateTags(in: text.index(text.startIndex, offsetBy: lead.count)..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = String(text[range])
            let joins = tag == .preposition || tag == .conjunction || tag == .particle
                || joiningWords.contains(word) || (tag == .verb && word.hasSuffix("ing"))
            if joins, !words.isEmpty { return false }
            words.append(word)
            return true
        }
        let plain = words.filter { $0.rangeOfCharacter(from: .decimalDigits) == nil && $0.count >= 3 }
        guard let head = plain.last else { return nil }
        return (words.joined(separator: " "), head)
    }

    /// Words that end a kind and start its topic, for when the tagger misses one.
    private static let joiningWords: Set<String> = ["for", "on", "of", "about", "from", "with", "to", "in",
                                                    "and", "by", "using", "without", "via"]
}

/// The second line under a file in Pip's window: Pip's description of it,
/// else the document's own title when that says more than its name.
/// Fetched for the rows on screen; a new description replaces it.
@MainActor
final class FileNoteCache: ObservableObject {

    static let shared = FileNoteCache()
    @Published private(set) var lines: [String: String] = [:]
    private var asked = Set<String>()

    func line(for url: URL) -> String? { lines[url.path] }

    func want(_ urls: [URL]) {
        let paths = urls.map(\.path).filter { !asked.contains($0) }
        guard !paths.isEmpty else { return }
        asked.formUnion(paths)
        Task {
            let notes = await ContentStore.shared.notes(for: paths)
            for path in paths {
                guard let note = notes[path] else { continue }
                let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                if let about = note.about {
                    lines[path] = about
                } else if let title = note.title, !title.isEmpty,
                          title.caseInsensitiveCompare(stem) != .orderedSame,
                          title.caseInsensitiveCompare((path as NSString).lastPathComponent) != .orderedSame {
                    lines[path] = title
                }
            }
        }
    }

    /// A description was just written: fetch it now, so a row on screen updates.
    func forget(_ path: String) {
        asked.remove(path)
        want([URL(fileURLWithPath: path)])
    }
}
