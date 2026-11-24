import Foundation

/// One reading of a search: the words, the kind of file, the time, the
/// folder, and whether it's about the owner.
struct QueryParse: CustomStringConvertible {

    /// Words to look for, stemmed: kind, chat and (when a time was given)
    /// time words removed. Falls back to every word but chat words when that
    /// leaves nothing ("screenshots", "pdf").
    let words: [String]
    /// The words a file must contain to count as matching all of them:
    /// `words` minus words that describe a file ("paper", "latest"), and
    /// two-letter words, which the indexes often drop (numbers always count).
    let required: [String]
    /// Kind words as typed (stemmed): "picture", "pdf".
    let kindWords: [String]
    /// The file extensions asked for; empty means any.
    let extensions: Set<String>
    /// Formats a genre word prefers ("slides" → pptx, key); never a filter.
    let preferred: Set<String>
    /// Formats to score as a type match: the asked ones and the preferred.
    var typeHints: Set<String> { extensions.union(preferred) }
    let time: QueryTime.Window?
    /// "my pic", "photo of me", "me in…" — recorded, not acted on yet (a
    /// face filter is a later task).
    let me: Bool
    /// "latest", "newest", "most recent", "upcoming": newest first.
    let latest: Bool
    /// "on my desktop": a folder filter, not a word.
    let folder: String?
    /// The content as typed, unstemmed and in order ("yellow suit") — for
    /// models that read words, not stems ("riding" isn't "rid").
    let phrase: String

    /// A drawing or illustration was asked for: pictures, the word kept.
    let art: Bool


    /// Only pictures were asked for ("pic", "photo", "image", "selfie", or a
    /// drawing).
    var wantsPictures: Bool { art || kindWords.contains { Self.pictureWords.contains($0) } }

    init(_ text: String, timeHint: String? = nil) {
        let all = Tokens.query(text)
        time = QueryTime.window(in: timeHint ?? text)
        let timed = time
        let artStems = Set(Tokens.of(text).filter(Self.artWords.contains).flatMap(Tokens.query))
        let kindWords = all.filter { Self.extensions(for: $0) != nil }
        let art = kindWords.isEmpty && !artStems.isEmpty
        self.kindWords = kindWords
        self.art = art
        extensions = art ? Self.images
            : kindWords.reduce(into: Set<String>()) { $0.formUnion(Self.extensions(for: $1) ?? []) }
        let pictures = art || kindWords.contains { Self.pictureWords.contains($0) }
        preferred = all.reduce(into: Set<String>()) { $0.formUnion(Self.genreExtensions(for: $1) ?? []) }
        // "all research papers", "every receipt": how many, not what. Only
        // first — "Attention Is All You Need" keeps its "all".
        let leading = Set(["all", "every", "each"])
        let asked = all.enumerated().filter { index, word in
            !Self.chatWords.contains(word)
                && !(leading.contains(word) && all.prefix(index).allSatisfy(Self.chatWords.contains) && all.count > index + 1)
        }.map(\.element)
        // Typed like a file name ("data.png"): the extension is part of the
        // name being asked for, as well as its kind.
        let lowered = text.lowercased()
        // An order, not content — like a time once it's the filter. Searched
        // for, "latest" had to be in the file: "flight ticket latest" found
        // CSVs and our own code that say all three, never the ticket.
        latest = lowered.range(of: #"\b(latest|newest|most recent|upcoming)\b"#, options: .regularExpression) != nil
        let order = latest ? Set(Tokens.query("latest newest most recent upcoming")) : []
        // From the words as typed (the hint carries them when Pip's finder
        // has already dropped "on my"); "documents" only as a place, since
        // "visa documents" is a kind of file.
        let said = (timeHint ?? text).lowercased()
        let place = said.range(of: #"\b(?:on|in|from|at) (?:my |the )?(desktop|downloads?|documents)\b|\b(desktop|downloads?|documents) folder\b"#,
                               options: .regularExpression).map { String(said[$0]) }
            ?? ["desktop", "download", "downloads"].first { word in Tokens.of(said).contains(word) }
        folder = place.map { phrase in
            phrase.contains("desktop") ? "Desktop" : phrase.contains("download") ? "Downloads" : "Documents"
        }
        let placeWords = folder == nil ? [] : Set(Tokens.query("desktop download downloads document documents folder"))
        let attached = Set(kindWords.filter { lowered.range(of: "\\w\\.\($0)\\b", options: .regularExpression) != nil })
        let content = asked.filter {
            (Self.extensions(for: $0) == nil || attached.contains($0)) && !(timed != nil && QueryTime.isTimeWord($0))
                && !order.contains($0) && !placeWords.contains($0)
        }
        words = content.isEmpty ? (asked.isEmpty ? all : asked) : content
        required = content.filter {
            !Self.describing.contains($0) && !(timed != nil && QueryTime.isTimeWord($0))
                && !artStems.contains($0) && !(pictures && Self.personWords.contains($0))
                && ($0.count >= 3 || $0.contains(where: \.isNumber))
        }
        me = text.lowercased().range(of: Self.mePattern, options: .regularExpression) != nil
        let kept = Set(words)
        let typed = Tokens.of(text).filter { word in Tokens.query(word).first.map(kept.contains) ?? false }
        phrase = typed.isEmpty ? text : typed.joined(separator: " ")
    }

    var description: String {
        var parts = ["words=[\(words.joined(separator: ","))]"]
        if !kindWords.isEmpty { parts.append("kind=\(kindWords.joined(separator: ","))") }
        if let time { parts.append("time=\(time.label)") }
        if art { parts.append("art=true") }
        if me { parts.append("me=true") }
        if latest { parts.append("latest=true") }
        if let folder { parts.append("folder=\(folder)") }
        return "query: " + parts.joined(separator: " ")
    }

    // MARK: - The lists

    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]
    private static let photos: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    private static let slides: Set<String> = ["pptx", "ppt", "key"]
    private static let sheets: Set<String> = ["xlsx", "xls", "csv", "numbers"]
    private static let wordDocs: Set<String> = ["doc", "docx"]
    private static let videos: Set<String> = ["mp4", "mov", "m4v"]

    /// Kind words → the extensions they mean. Stems: queries are stemmed
    /// ("pictures" → "picture"), and short plurals ("pics") aren't.
    static let kinds: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for word in ["image", "picture", "pic", "pics"] { map[word] = images }
        for word in ["photo", "selfie"] { map[word] = photos }
        map["screenshot"] = ["png", "jpg", "jpeg"]
        map["png"] = ["png"]
        map["jpg"] = ["jpg", "jpeg"]
        map["jpeg"] = ["jpg", "jpeg"]
        map["heic"] = ["heic"]
        map["pdf"] = ["pdf"]
        map["pdfs"] = ["pdf"]
        map["doc"] = wordDocs.union(["pages", "rtf", "odt"])
        map["docx"] = wordDocs
        map["word"] = wordDocs
        map["powerpoint"] = ["pptx", "ppt"]
        for word in ["sheet", "spreadsheet"] { map[word] = sheets }
        map["excel"] = ["xlsx", "xls"]
        map["csv"] = ["csv"]
        for word in ["video", "clip", "movie"] { map[word] = videos }
        for word in ["zip", "archive"] { map[word] = ["zip"] }
        return map
    }()

    /// Kinds of document, not formats: lecture slides are mostly PDFs, and
    /// "visa documents" are scans. These prefer their formats but never
    /// filter, and stay words to search — Pip's descriptions name them.
    static let genres: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for word in ["slide", "slides", "deck", "presentation"] { map[word] = slides }
        map["document"] = ["pdf", "doc", "docx", "pages", "rtf", "txt", "md"]
        return map
    }()

    static func genreExtensions(for word: String) -> Set<String>? {
        genres[word] ?? (word.hasSuffix("s") ? genres[String(word.dropLast())] : nil)
    }

    static func extensions(for word: String) -> Set<String>? {
        kinds[word] ?? (word.hasSuffix("s") ? kinds[String(word.dropLast())] : nil)
    }

    private static let pictureWords: Set<String> = ["image", "picture", "pic", "pics", "photo", "selfie"]

    /// Words for a picture made by hand, as typed. Not "art" ("state of the
    /// art") or "draw" ("lucky draw").
    private static let artWords: Set<String> = [
        "drawing", "drawings", "sketch", "sketches", "illustration", "illustrations",
        "painting", "paintings", "artwork", "artworks",
    ]

    /// Who is in a picture (stemmed): searched for, never required of a
    /// picture — captions only ever say "person", so "girl" ruled out every
    /// photo of one.
    private static let personWords: Set<String> = [
        "girl", "boy", "woman", "women", "man", "men", "lady", "ladies", "ladie", "guy", "guys",
        "kid", "kids", "child", "children", "baby", "person", "people",
    ]

    /// How a request is phrased, never what a file says. Not "you", "need",
    /// "want": they're in titles ("Attention Is All You Need").
    static let chatWords: Set<String> = [
        "find", "show", "get", "give", "me", "look", "search", "locate", "where", "which", "open",
        "please", "can", "am", "im", "having", "holding", "showing", "with", "called", "named",
        "some", "any", "device", "mac", "computer", "laptop", "file", "files",
        "wearing", "wear", "around", "roughly", "approximately", "during", "sometime", "somewhere",
        // "sydney to tokyo flight": "to" sent Spotlight looking for it in
        // every name (16.5 s), and Pip got a partial list.
        "to", "from",
        // "the latest one", "that one": which thing, not what's in it — the
        // ticket lacked "one", datasets that said it won.
        "one", "ones",
    ]

    /// Words that describe a file rather than say what's in it: searched
    /// for, never required.
    static let describing: Set<String> = [
        "paper", "papers", "article", "slide", "slides", "deck", "presentation", "document", "documents", "today", "yesterday", "last", "this", "week", "weeks",
        "month", "months", "year", "years", "ago", "day", "days", "recent", "recently",
        "latest", "newest", "new", "old", "older",
    ]

    private static let mePattern =
        #"\b(?:my (?:pic|pics|picture|pictures|photo|photos|selfie|selfies)|(?:of|with) me\b|me in\b|i(?:'m| am) (?:wearing|in)\b|selfies?\b)"#
}
