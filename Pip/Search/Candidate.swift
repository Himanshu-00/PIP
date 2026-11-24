import AppKit

/// One file on its way through the pipeline, filled in stage by stage.
struct Candidate: Identifiable, Equatable, Sendable {

    let url: URL
    var id: URL { url }

    // MARK: Free, from Spotlight

    var displayName: String
    var modified: Date?
    var lastOpened: Date?
    var useCount: Int
    /// The URL a file was downloaded from. Searchable text nobody thinks of —
    /// "the pdf from arxiv" is a real query, and this is the only place that
    /// information lives.
    var whereFrom: String?

    // MARK: Filled in later, only for survivors

    /// Extracted text, capped. Nil means nobody has looked yet; empty means
    /// someone looked and there was nothing.
    var text: String?
    /// The title a PDF gives itself, which is frequently nothing like its
    /// filename and frequently much better.
    var pdfTitle: String?

    // MARK: Scoring

    var features = Features()
    var score: Double = 0
    /// Known to contain every word of the query — in its name, title or text
    /// (or a phrase/"every word" hit from the index or Spotlight). Strict
    /// matching puts these above everything else.
    var matchesAll = false
    /// How much the picture looks like the query (photo vectors), 0…1; 0 =
    /// not found by looks.
    var looks = 0.0
    /// Text evidence from the index or Spotlight, 0…1; a search's own read can
    /// raise `textMatch` above it, never below.
    var indexedTextMatch = 0.0

    var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"]
            .contains(url.pathExtension.lowercased())
    }

    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }

    /// Identity for the cache. Path alone isn't enough — the interesting case
    /// is a file that was edited, which keeps its path and changes everything
    /// else about what it says.
    var cacheKey: String {
        let stamp = modified?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(stamp))"
    }
}

/// What the ranker sees. Deliberately a fixed-width vector of plain numbers:
/// it's what gets logged, what gets trained on, and what the weights multiply,
/// so all three stay in step by construction.
struct Features: Equatable, Sendable {

    /// Query words appearing in the filename, as a fraction of query words.
    var nameMatch: Double = 0
    /// Query words appearing in the download URL.
    var whereFromMatch: Double = 0
    /// Query words appearing anywhere in the extracted text.
    var textMatch: Double = 0
    /// 1 for something touched today, decaying with a half-life of a week.
    var recency: Double = 0
    /// How often it's been opened, squashed.
    var familiarity: Double = 0
    /// The query named a type — "pdf", "screenshot" — and this is one.
    var typeMatch: Double = 0
    /// Spotlight's own position in the result list, normalised. Free signal:
    /// macOS has opinions and they aren't worthless.
    var retrievalRank: Double = 0

    /// Whether `textMatch` was measured (zero can mean "never read").
    var textWasMeasured = false

    /// Closeness in meaning, 0…1; meets `textMatch` only in `vector`.
    var semanticMatch: Double = 0

    static let count = 7
    static let names = ["nameMatch", "whereFromMatch", "textMatch",
                        "recency", "familiarity", "typeMatch", "retrievalRank"]
    /// Position of `textMatch` in `vector`, for scoring around it when it
    /// wasn't measured. Tied to the order above.
    static let textIndex = 2

    var vector: [Double] {
        [nameMatch, whereFromMatch, max(textMatch, semanticMatch),
         recency, familiarity, typeMatch, retrievalRank]
    }

    init() {}

    init(vector: [Double]) {
        guard vector.count == Self.count else { return }
        nameMatch = vector[0]; whereFromMatch = vector[1]
        textMatch = vector[2]; recency = vector[3]
        familiarity = vector[4]; typeMatch = vector[5]
        retrievalRank = vector[6]
    }
}
