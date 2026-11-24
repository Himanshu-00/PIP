import Foundation
import NaturalLanguage

/// Search results grouped by what they are, in milliseconds, with no list
/// of categories: each file's signature — Pip's description of it
/// (`DocumentNotes`), else its title, caption or opening, plus its folder —
/// becomes a meaning vector, and files whose vectors are close form a group.
/// A group is named from the words its members share, so names get better
/// as Pip describes more files. Files that fit nowhere go to "Other".
enum ResultGroups {

    struct Group: Sendable {
        var name: String
        var urls: [URL]
        /// Named from Pip's descriptions (not "Like …" or "Other").
        var named: Bool = false
    }

    /// How close two signatures must be (cosine, average linkage) to share a group.
    static var threshold: Float = 0.62

    /// Groups `urls` (in their ranked order); nil when there's nothing to group
    /// by or fewer than `minGroups` real groups (search wants two: one group
    /// and a few odd ones out isn't a split).
    static func group(_ urls: [URL], query: String, minGroups: Int = 2) async -> [Group]? {
        // One folder for all (organising it): the folder says nothing.
        let oneFolder = Set(urls.map { $0.deletingLastPathComponent().path }).count == 1
        guard urls.count >= 4 else { return nil }
        let notes = await ContentStore.shared.notes(for: urls.map(\.path))
        let signatures = urls.map { url -> String in
            let note = notes[url.path]
            let folder = url.deletingLastPathComponent().lastPathComponent
            let what = note?.about ?? note?.caption
                ?? [note?.title, note.map { String($0.opening.prefix(200)) }].compactMap { $0 }.joined(separator: ". ")
            return (what.isEmpty ? url.deletingPathExtension().lastPathComponent : what) + (oneFolder ? "" : ". In " + folder)
        }
        let vectors = await Task.detached(priority: .userInitiated) { SemanticIndex.embed(signatures) }.value
        guard let vectors, vectors.count == urls.count else { return nil }

        // First by the kind Pip wrote ("Transformer paper on …" and "RLHF
        // paper on …" are both papers), however different their topics.
        let abouts = urls.map { notes[$0.path]?.about }
        let kinds = abouts.map { $0.flatMap(kind(of:)) }
        var byKind: [String: [Int]] = [:]
        for (index, kind) in kinds.enumerated() { if let kind { byKind[Tokens.stem(kind.head), default: []].append(index) } }
        let kindGroups = byKind.values.filter { $0.count >= 2 }.map { $0.sorted() }
        let kinded = Set(kindGroups.flatMap { $0 })

        // The rest by meaning. Average linkage: merge the closest pair while it's close enough.
        var clusters = urls.indices.filter { !kinded.contains($0) }.map { [$0] }
        func similarity(_ a: [Int], _ b: [Int]) -> Float {
            var total: Float = 0
            for i in a { for j in b { total += zip(vectors[i], vectors[j]).reduce(0) { $0 + $1.0 * $1.1 } } }
            return total / Float(a.count * b.count)
        }
        while clusters.count > 1 {
            var best: (Int, Int, Float) = (0, 0, -1)
            for i in clusters.indices { for j in clusters.indices where j > i {
                let s = similarity(clusters[i], clusters[j])
                if s > best.2 { best = (i, j, s) }
            } }
            guard best.2 >= threshold else { break }
            clusters[best.0] += clusters[best.1]
            clusters.remove(at: best.1)
        }

        let meaningGroups = clusters.filter { $0.count >= 2 }.map { $0.sorted() }
        let real = kindGroups + meaningGroups
        guard real.count >= max(1, minGroups) else { return nil }
        let loose = clusters.filter { $0.count < 2 }.flatMap { $0 }.sorted()
        // Stems, so "assignments" keeps "assignment" out of the names too.
        let queryWords = Set(Tokens.of(query).map(Tokens.stem))
        var groups = real.sorted { $0[0] < $1[0] }.map { members in
            let named = kinded.contains(members[0])
                ? kindName(members.compactMap { index in kinds[index].map { ($0.phrase, abouts[index] ?? "") } })
                : name(of: members, abouts: abouts, avoiding: queryWords)
            return Group(name: named ?? like(urls[members[0]]), urls: members.map { urls[$0] }, named: named != nil)
        }
        if !loose.isEmpty { groups.append(Group(name: "Other", urls: loose.map { urls[$0] })) }
        return groups
    }

    /// From Pip's descriptions only (they never hold people's names): the words
    /// most of the group shares, in the first described member's order
    /// ("Assignment marking rubric"). Until half the group is described:
    /// nil (shown as "Like" and its best match's name).
    private static func name(of members: [Int], abouts: [String?], avoiding: Set<String>) -> String? {
        let described = members.compactMap { abouts[$0] }
        if described.count * 2 >= members.count {
            let words = described.map { Tokens.of($0).filter { $0.count >= 3 && !avoiding.contains(Tokens.stem($0)) } }
            var count: [String: Int] = [:]
            for list in words { for word in Set(list) { count[word, default: 0] += 1 } }
            let needed = max(2, Int((Double(described.count) * 0.6).rounded(.up)))
            let shared = Set(count.filter { $0.value >= needed }.keys)
            var seen = Set<String>()
            let ordered = (words.first ?? []).filter { shared.contains($0) && seen.insert($0).inserted }
            // Nothing shared: the group has no name of its own.
            guard !ordered.isEmpty else { return nil }
            let picked = Array(ordered.prefix(3))
            // Each word as the description wrote it ("CS101", not "cs101").
            let original = described.first ?? ""
            let phrase = picked.map { word in
                original.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                               options: [.regularExpression, .caseInsensitive]).map { String(original[$0]) } ?? word
            }.joined(separator: " ")
            if !phrase.isEmpty { return phrase.prefix(1).uppercased() + phrase.dropFirst() }
        }
        return nil
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

    /// A kind group's name: the words most of its kinds share, plural and
    /// written as the first description wrote them ("Transformer paper",
    /// "RLHF paper" → "Papers"). The searched words stay: they're the kind.
    private static func kindName(_ kinds: [(phrase: String, about: String)]) -> String? {
        // Words as the phrase has them, so "Week 11 slides" ends "11 slides".
        let words = kinds.map { $0.phrase.split(separator: " ").map(String.init) }
        var count: [String: Int] = [:]
        for list in words { for word in Set(list) { count[word, default: 0] += 1 } }
        let needed = max(2, Int((Double(kinds.count) * 0.6).rounded(.up)))
        // The run of shared words that ends at the kind ("Week 11 slides" and
        // "Week 7 slides" → "slides"; "Transformer paper", "RLHF paper" → "paper").
        var run: [String] = []
        for word in (words.first ?? []).reversed() {
            guard count[word, default: 0] >= needed, run.count < 3 else { break }
            run.insert(word, at: 0)
        }
        guard !run.isEmpty else { return nil }
        let original = kinds.first?.about ?? ""
        let phrase = run.map { word in
            original.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                           options: [.regularExpression, .caseInsensitive]).map { String(original[$0]) } ?? word
        }.joined(separator: " ")
        let plural = String(AttributedString(localized: "^[\(2) \(phrase)](inflect: true)").characters)
            .replacingOccurrences(of: #"^2 "#, with: "", options: .regularExpression)
        return plural.prefix(1).uppercased() + plural.dropFirst()
    }

    private static func like(_ url: URL) -> String {
        let best = url.deletingPathExtension().lastPathComponent
        return "Like " + (best.count > 32 ? String(best.prefix(31)) + "…" : best)
    }
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
