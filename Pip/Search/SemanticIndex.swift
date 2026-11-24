import Foundation
import NaturalLanguage
import SQLite3
import Accelerate

/// Search by meaning: a vector per passage read (Apple's sentence embedding,
/// on-device), in its own `semantic.db`. "Ask your files" embeds deeper
/// passages on demand and caches them in memory only. Best-effort.
actor SemanticIndex {

    static let shared = SemanticIndex()

    struct Match: Sendable {
        let url: URL
        /// Cosine similarity between the query and the passage, -1...1.
        let similarity: Double
        let passage: String
    }

    // MARK: - Sizes

    /// Characters per passage. About a paragraph: long enough to carry an
    /// idea, short enough that one vector can still represent it. Sentence
    /// embeddings blur badly over a whole page.
    static let passageLength = 420
    /// Passages kept per document. The extract is capped at 4,000 characters
    /// already, and the opening of a document is where it says what it is.
    static let passagesPerDocument = 5
    /// Documents kept before the oldest are dropped. At five passages of 512
    /// floats each, eight thousand documents is about 80 MB on disk at the
    /// very most; most people will never come near it.
    static let documentLimit = 8_000

    // MARK: - State

    private var database: OpaquePointer?
    private var ready = false
    private var attemptedOpen = false
    private let location: URL

    private var embedding: NLEmbedding?
    private var attemptedEmbedding = false
    private var dimension = 0

    /// Every passage vector in one flat array (one vDSP pass per query); rows are
    /// marked dead, never removed in place. Loaded on demand.
    private var loaded = false
    private var rowIDs: [Int64] = []
    private var rowPaths: [String] = []
    private var matrix: [Float] = []
    private var dead: Set<Int> = []
    private var rowsByPath: [String: [Int]] = [:]

    private init() {
        location = AppFolders.support.appendingPathComponent("semantic.db")
    }

    // MARK: - The model

    private func model() -> NLEmbedding? {
        if !attemptedEmbedding {
            attemptedEmbedding = true
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
            dimension = embedding?.dimension ?? 0
        }
        return dimension > 0 ? embedding : nil
    }

    /// Whether this Mac has the sentence embedding at all.
    func isAvailable() -> Bool { model() != nil }

    /// Unit-length, so cosine similarity is a plain dot product.
    private func vector(for text: String) -> [Float]? {
        guard let engine = model(),
              let raw = engine.vector(for: text),
              raw.count == dimension
        else { return nil }
        let floats = raw.map { Float($0) }
        let norm = sqrt(floats.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return floats.map { $0 / norm }
    }

    // MARK: - Opening

    private func open() {
        guard !attemptedOpen else { return }
        attemptedOpen = true
        guard model() != nil else { return }

        let folder = location.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard sqlite3_open_v2(location.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            database = nil
            return
        }
        SQLite.exec(database, "PRAGMA journal_mode = WAL")
        SQLite.exec(database, "PRAGMA synchronous = NORMAL")

        // A new embedding dimension means a new model: start over.
        if SQLite.userVersion(database) != dimension {
            SQLite.exec(database, "DROP TABLE IF EXISTS passages")
            SQLite.exec(database, "DROP TABLE IF EXISTS pruned")
            SQLite.exec(database, "PRAGMA user_version = \(dimension)")
        }

        let schema = [
            """
            CREATE TABLE IF NOT EXISTS passages (
                id     INTEGER PRIMARY KEY,
                path   TEXT NOT NULL,
                mtime  REAL NOT NULL,
                idx    INTEGER NOT NULL,
                text   TEXT NOT NULL,
                vec    BLOB NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS passages_path ON passages(path)",
            // Documents dropped by `prune`, at the mtime they had: see there.
            "CREATE TABLE IF NOT EXISTS pruned (path TEXT PRIMARY KEY, mtime REAL NOT NULL)",
            // Clears vectors of email a build with mail search may have
            // stored. See the matching note in ContentStore.
            "DELETE FROM passages WHERE path LIKE '%/Library/Mail/%'",
            "DELETE FROM passages WHERE path LIKE '/Users/%/Library/%'",
        ]
        for statement in schema where !SQLite.exec(database, statement) {
            sqlite3_close(database)
            database = nil
            return
        }
        ready = true
        SQLite.excludeFromBackup(location)
    }

    // MARK: - Writing

    /// Do we already hold vectors for this version of the file?
    private func isCurrent(path: String, stamp: Double) -> Bool {
        guard ready, let database else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Held, or pruned at this version: either way, don't embed it again.
        guard sqlite3_prepare_v2(database, """
            SELECT mtime FROM passages WHERE path = ?1
            UNION ALL SELECT mtime FROM pruned WHERE path = ?1 LIMIT 1
            """, -1, &statement, nil) == SQLITE_OK else { return false }
        SQLite.bind(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return abs(sqlite3_column_double(statement, 0) - stamp) < 1
    }

    /// Embeds a document's passages unless current (`replace`: always). Returns
    /// whether any work was done.
    @discardableResult
    func add(path: String, modified: Date?, title: String?, text: String, replace: Bool = false) -> Bool {
        open()
        guard ready, let database, !text.isEmpty, !DirectScan.isExcluded(path) else { return false }
        let stamp = modified?.timeIntervalSince1970 ?? 0
        if !replace, isCurrent(path: path, stamp: stamp) { return false }

        var rows: [(text: String, vector: [Float])] = []
        for passage in Self.passages(from: text, title: title) {
            if let embedded = vector(for: passage) { rows.append((passage, embedded)) }
        }
        guard !rows.isEmpty else { return false }

        SQLite.exec(database, "BEGIN")
        deleteRows(path: path)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO passages (path, mtime, idx, text, vec) VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            SQLite.exec(database, "ROLLBACK")
            return false
        }

        var inserted: [(id: Int64, vector: [Float])] = []
        for (index, row) in rows.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            SQLite.bind(statement, 1, path)
            sqlite3_bind_double(statement, 2, stamp)
            sqlite3_bind_int(statement, 3, Int32(index))
            SQLite.bind(statement, 4, row.text)
            row.vector.withUnsafeBytes { SQLite.bind(statement, 5, blob: $0) }
            if sqlite3_step(statement) == SQLITE_DONE {
                inserted.append((sqlite3_last_insert_rowid(database), row.vector))
            }
        }
        SQLite.exec(database, "COMMIT")

        // Keep a loaded matrix in step rather than throwing it away, so a
        // sweep that reads files mid-search makes them findable by meaning in
        // the same search.
        if loaded {
            tombstone(path)
            for row in inserted { appendRow(id: row.id, path: path, vector: row.vector) }
        }
        return true
    }

    func forget(path: String) {
        open()
        guard ready else { return }
        deleteRows(path: path)
        if loaded { tombstone(path) }
    }

    /// A file was renamed or moved: its passages follow it, no re-embedding.
    func rename(from old: String, to new: String) {
        open()
        guard ready, let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "UPDATE passages SET path = ? WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, new)
        SQLite.bind(statement, 2, old)
        sqlite3_step(statement)
        if loaded { release() }     // reloaded with the new path on the next search
    }

    private func deleteRows(path: String) {
        guard let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "DELETE FROM passages WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, path)
        sqlite3_step(statement)
    }

    /// Passages at word boundaries, the title on the first.
    static func passages(from text: String, title: String?,
                         limit: Int = SemanticIndex.passagesPerDocument) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            if !current.isEmpty, current.count + word.count + 1 > passageLength {
                out.append(current)
                current = ""
                if out.count == limit { break }
            }
            current += (current.isEmpty ? "" : " ") + String(word)
        }
        if out.count < limit, !current.isEmpty { out.append(current) }
        if let title, !title.isEmpty, !out.isEmpty { out[0] = title + ". " + out[0] }
        return out
    }

    // MARK: - Ask your files: whole documents, on demand

    /// Overlapping passages over a whole document, no per-document limit —
    /// for "Ask your files", where the answer can be on page 30. The overlap
    /// keeps a sentence cut at a boundary whole in one of the two passages.
    static func overlappingPassages(from text: String, overlapWords: Int = 12) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var out: [String] = []
        var start = 0
        while start < words.count {
            var end = start
            var length = 0
            while end < words.count, length == 0 || length + words[end].count + 1 <= passageLength {
                length += words[end].count + 1
                end += 1
            }
            out.append(words[start..<end].joined(separator: " "))
            if end >= words.count { break }
            start = max(start + 1, end - overlapWords)
        }
        return out
    }

    /// Unit vectors for many texts, eight threads at once (~6 ms a passage). Nil
    /// without a sentence embedding. Heavy — off the main actor.
    nonisolated static func embed(_ texts: [String]) -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        let lanes = min(8, texts.count)
        let engines = (0..<lanes).compactMap { _ in NLEmbedding.sentenceEmbedding(for: .english) }
        guard engines.count == lanes, engines[0].dimension > 0 else { return nil }
        let results = UnsafeMutableBufferPointer<[Float]>.allocate(capacity: texts.count)
        results.initialize(repeating: [])
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: texts.count, by: lanes) {
                guard let raw = engines[lane].vector(for: texts[index]) else { continue }
                let floats = raw.map { Float($0) }
                let norm = sqrt(floats.reduce(0) { $0 + $1 * $1 })
                if norm > 0 { results[index] = floats.map { $0 / norm } }
            }
        }
        return Array(results)
    }

    /// Deep text and passage vectors of the last few documents asked about,
    /// keyed by path and modification date, so a follow-up question costs
    /// one embedding. In memory only; a few hundred KB each.
    private var askTexts: [String: String] = [:]
    private var askVectors: [String: [String: [Float]]] = [:]
    private var askOrder: [String] = []
    private let askLimit = 8

    func askCached(_ key: String) -> (text: String?, vectors: [String: [Float]]) {
        (askTexts[key], askVectors[key] ?? [:])
    }

    func askRemember(_ key: String, text: String, vectors: [String: [Float]]) {
        askTexts[key] = text
        askVectors[key, default: [:]].merge(vectors) { _, new in new }
        askOrder.removeAll { $0 == key }
        askOrder.append(key)
        while askOrder.count > askLimit {
            let evict = askOrder.removeFirst()
            askTexts.removeValue(forKey: evict)
            askVectors.removeValue(forKey: evict)
        }
    }

    // MARK: - The in-memory matrix

    private func load() {
        guard !loaded else { return }
        open()
        guard ready, let database else { return }

        rowIDs = []; rowPaths = []; matrix = []; dead = []; rowsByPath = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id, path, vec FROM passages",
                                 -1, &statement, nil) == SQLITE_OK else { return }

        while sqlite3_step(statement) == SQLITE_ROW {
            let bytes = Int(sqlite3_column_bytes(statement, 2))
            guard bytes == dimension * MemoryLayout<Float>.size,
                  let blob = sqlite3_column_blob(statement, 2),
                  let path = SQLite.string(statement, 1) else { continue }
            let floats = Array(UnsafeBufferPointer(
                start: blob.assumingMemoryBound(to: Float.self), count: dimension))
            appendRow(id: sqlite3_column_int64(statement, 0), path: path, vector: floats)
        }
        loaded = true
    }

    private func appendRow(id: Int64, path: String, vector: [Float]) {
        rowsByPath[path, default: []].append(rowIDs.count)
        rowIDs.append(id)
        rowPaths.append(path)
        matrix.append(contentsOf: vector)
    }

    private func tombstone(_ path: String) {
        for row in rowsByPath[path] ?? [] { dead.insert(row) }
        rowsByPath[path] = nil
    }

    /// Hands the memory back. Called when the search panel closes — this is a
    /// background app, and a matrix nobody is querying is dead weight.
    func release() {
        loaded = false
        rowIDs = []; rowPaths = []; matrix = []; dead = []; rowsByPath = [:]
    }

    /// One dot product per passage.
    private func scores(for query: [Float]) -> [Float] {
        let count = rowIDs.count
        var out = [Float](repeating: 0, count: count)
        guard count > 0, dimension > 0, matrix.count == count * dimension else { return out }
        let length = vDSP_Length(dimension)
        let width = dimension
        matrix.withUnsafeBufferPointer { base in
            query.withUnsafeBufferPointer { probe in
                guard let start = base.baseAddress, let q = probe.baseAddress else { return }
                for row in 0..<count {
                    var value: Float = 0
                    vDSP_dotpr(start + row * width, 1, q, 1, &value, length)
                    out[row] = value
                }
            }
        }
        return out
    }

    // MARK: - Searching

    /// The documents closest in meaning to the query, best passage each.
    func search(_ query: String, limit: Int = 30) -> [Match] {
        open()
        guard ready, let probe = vector(for: query) else { return [] }
        load()
        let scored = scores(for: probe)

        var best: [String: (row: Int, score: Float)] = [:]
        for row in scored.indices where !dead.contains(row) {
            let path = rowPaths[row]
            if let held = best[path], held.score >= scored[row] { continue }
            best[path] = (row, scored[row])
        }

        return best
            .sorted { $0.value.score > $1.value.score }
            .prefix(limit)
            .map { entry in
                Match(url: URL(fileURLWithPath: entry.key),
                      similarity: Double(entry.value.score),
                      passage: passageText(id: rowIDs[entry.value.row]) ?? "")
            }
    }

    private func passageText(id: Int64) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT text FROM passages WHERE id = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SQLite.string(statement, 0)
    }

    // MARK: - Housekeeping

    /// Drops the oldest-embedded documents past the limit, noting them in
    /// `pruned`. Captioned photos are kept.
    func prune() {
        open()
        guard ready, let database else { return }
        let overflow = """
            SELECT path FROM passages GROUP BY path HAVING max(idx = 0 AND text LIKE 'Photo: %') = 0
            ORDER BY max(id) DESC LIMIT -1 OFFSET \(Self.documentLimit)
            """
        SQLite.exec(database, "INSERT OR REPLACE INTO pruned (path, mtime) "
                    + "SELECT path, max(mtime) FROM passages WHERE path IN (\(overflow)) GROUP BY path")
        SQLite.exec(database, "DELETE FROM passages WHERE path IN (\(overflow))")
        if sqlite3_changes(database) > 0 { release() }
    }

    /// For diagnostics.
    func summary() -> String {
        open()
        guard ready, let database else {
            return "semantic index unavailable — no sentence embedding on this Mac"
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database,
                                 "SELECT count(DISTINCT path), count(*) FROM passages",
                                 -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return "semantic index empty" }
        let documents = Int(sqlite3_column_int64(statement, 0))
        let passages = Int(sqlite3_column_int64(statement, 1))
        return "semantic index: \(documents) documents, \(passages) passages, \(dimension)-d vectors"
    }
}
