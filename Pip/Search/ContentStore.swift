import Foundation
import SQLite3

/// The text of every file already read, kept between launches (SQLite FTS5).
/// A cache, not a crawl; best-effort: if anything fails, search carries on
/// without it.
actor ContentStore {

    static let shared = ContentStore()

    /// One row of what we know about a file we've read.
    /// `Sendable` because these cross actor boundaries by design: the store is
    /// its own actor, its callers are the main actor and `TextExtractor`.
    struct Record: Sendable {
        var text: String
        var title: String?
        /// Section headings, one per line.
        var headings: String?
    }

    /// A hit from the full-text index.
    struct Hit: Sendable {
        var url: URL
        var title: String?
        /// FTS5's own BM25, negated so larger is better. Raw and unbounded;
        /// the caller normalises alongside its other candidates.
        var score: Double
        /// The query's words appear together, in order, in its name, title or
        /// text — "attention is all you need" on the paper's first page.
        var phrase = false
        /// Every query word appears somewhere in its title, headings or text.
        var allWords = false
    }

    private var database: OpaquePointer?
    /// Set once we know the schema is there and usable. Everything checks it.
    private var ready = false
    /// Opened once, on first use (not at login).
    private var attemptedOpen = false

    private let location: URL

    private init() {
        location = AppFolders.support.appendingPathComponent("content.db")
    }

    // No `deinit`: a process-lifetime singleton.

    // MARK: - Opening

    /// Opens on first use; after a failure, stays closed rather than retrying
    /// on every keystroke.
    private func open() {
        guard !attemptedOpen else { return }
        attemptedOpen = true

        let folder = location.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard sqlite3_open_v2(location.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            database = nil
            return
        }

        // WAL and NORMAL sync: a lost extraction costs a re-read, not data.
        SQLite.exec(database, "PRAGMA journal_mode = WAL")
        SQLite.exec(database, "PRAGMA synchronous = NORMAL")

        guard createSchema() else {
            sqlite3_close(database)
            database = nil
            return
        }
        ready = true
        // Fails harmlessly when the column is already there.
        SQLite.exec(database, "ALTER TABLE documents ADD COLUMN headings TEXT")
        // A photo's one-line description from Pip's vision (`PhotoCaptions`).
        // NULL = not captioned yet, '' = looked at, nothing to say (too small).
        SQLite.exec(database, "ALTER TABLE documents ADD COLUMN caption TEXT")
        // A document's one-line description from Pip's brain (`DocumentNotes`):
        // what kind of file it is and what it's about, in the model's own words.
        SQLite.exec(database, "ALTER TABLE documents ADD COLUMN about TEXT")
        v2Ready = createSchemaV2()
        if v2Ready { runOneTimeFixes() }
        SQLite.excludeFromBackup(location)
    }

    /// Corrections to what earlier builds stored, each run once (a `meta` key
    /// records it).
    private func runOneTimeFixes() {
        // Searches used to read whatever Spotlight returned, ~/Library
        // included. The tables above are cleared on every open; these are the
        // name and word indexes.
        if metaValue("library_purged") != "1" {
            SQLite.exec(database, "DELETE FROM search_fts WHERE path LIKE '/Users/%/Library/%'")
            SQLite.exec(database, "DELETE FROM names_trigram WHERE path LIKE '/Users/%/Library/%'")
            SQLite.exec(database, "DELETE FROM files WHERE path LIKE '/Users/%/Library/%'")
            setMeta("library_purged", "1")
        }
        // Re-read once for page-one titles and picture labels.
        if metaValue("image_labels_version") != "1" {
            let images = "(lower(path) LIKE '%.png' OR lower(path) LIKE '%.jpg' OR lower(path) LIKE '%.jpeg' "
                + "OR lower(path) LIKE '%.heic' OR lower(path) LIKE '%.webp')"
            SQLite.exec(database, "UPDATE documents SET mtime = -1 WHERE \(images)")
            SQLite.exec(database, "DELETE FROM unreadable WHERE \(images)")
            setMeta("image_labels_version", "1")
        }
        // Pictures dropped by the old prune are read once more.
        if metaValue("pictures_unpruned") != "1" {
            SQLite.exec(database, "DELETE FROM unreadable WHERE \(Self.imageSQL)")
            setMeta("pictures_unpruned", "1")
        }
        if metaValue("pdf_title_version") != "2" {
            SQLite.exec(database, "UPDATE documents SET headings = NULL WHERE lower(path) LIKE '%.pdf'")
            setMeta("pdf_title_version", "2")
        }
    }

    /// Returns false if anything at all went wrong — most usefully, if FTS5
    /// isn't available, in which case the virtual table creation fails and we
    /// disable the store rather than limping along with half a schema.
    private func createSchema() -> Bool {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS documents (
                id       INTEGER PRIMARY KEY,
                path     TEXT UNIQUE NOT NULL,
                mtime    REAL NOT NULL,
                title    TEXT,
                text     TEXT NOT NULL,
                read_at  REAL NOT NULL
            )
            """,
            // Not contentless: callers need the text back for scoring and snippets.
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
                text,
                content = 'documents',
                content_rowid = 'id',
                tokenize = 'unicode61'
            )
            """,
            // External-content FTS5 doesn't track its table by itself; these
            // three keep the index honest. The 'delete' command is how FTS5 is
            // told to retract a row it can no longer see.
            """
            CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
                INSERT INTO documents_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, text)
                VALUES ('delete', old.id, old.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, text)
                VALUES ('delete', old.id, old.text);
                INSERT INTO documents_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
            "CREATE INDEX IF NOT EXISTS documents_read_at ON documents(read_at)",
            // Files read that gave nothing; keeps the indexer from re-reading them.
            """
            CREATE TABLE IF NOT EXISTS unreadable (
                path   TEXT PRIMARY KEY,
                mtime  REAL NOT NULL
            )
            """,
            // Mail search was removed (copies of mail outside Mail's protected folder):
            // clear anything an old build stored.
            "DROP TABLE IF EXISTS mail",
            "DELETE FROM documents WHERE path LIKE '%/Library/Mail/%'",
            "DELETE FROM unreadable WHERE path LIKE '%/Library/Mail/%'",
            // Anything else from ~/Library a search read before it was
            // filtered out (Messages, app data). The home folder's own path
            // isn't known to SQL here, so match the shape.
            "DELETE FROM documents WHERE path LIKE '/Users/%/Library/%'",
            "DELETE FROM unreadable WHERE path LIKE '/Users/%/Library/%'",
        ]
        for statement in statements where !SQLite.exec(database, statement) { return false }
        return true
    }

    // MARK: - Schema v2: one index over name, title and text

    /// The v2 index exists (it needs FTS5's trigram tokenizer, SQLite 3.34+).
    private var v2Ready = false

    /// Version 2: `files` (every file in the usual folders), `search_fts` (name
    /// ×8, title ×6, headings ×4, text ×1) and `names_trigram` (any part of a
    /// name). `user_version` 2 = migration from v1 finished.
    private func createSchemaV2() -> Bool {
        // The index's columns changed (headings were added). FTS5 tables
        // can't gain a column, so an older one is dropped and rebuilt from
        // the stored documents by the normal migration.
        SQLite.exec(database, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        let layout = "name,title,headings,text"
        if metaValue("search_fts_layout") != layout {
            SQLite.exec(database, "DROP TABLE IF EXISTS search_fts")
            SQLite.exec(database, "PRAGMA user_version = 1")
            setMeta("v2_migrated_upto", "0")
            setMeta("search_fts_layout", layout)
        }
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS files (
                path     TEXT PRIMARY KEY,
                name     TEXT NOT NULL,
                kind     TEXT,
                folder   TEXT,
                size     INTEGER,
                mtime    REAL NOT NULL,
                seen_at  REAL NOT NULL,
                inode    INTEGER
            )
            """,
            "CREATE INDEX IF NOT EXISTS files_mtime ON files(mtime)",
            "CREATE INDEX IF NOT EXISTS files_inode ON files(inode)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
                name, title, headings, text, path UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2',
                prefix = '2 3'
            )
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS names_trigram USING fts5(
                name, path UNINDEXED,
                tokenize = 'trigram'
            )
            """,
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)",
        ]
        for statement in statements where !SQLite.exec(database, statement) { return false }
        return true
    }

    /// A file name as words: separators, camelCase and letter/digit boundaries
    /// split ("1706.03762v7.pdf" → "1706 03762 v 7 pdf").
    static func searchableName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        var out = ""
        var previous: Character?
        for character in name {
            if !(character.isLetter || character.isNumber) {
                if !out.hasSuffix(" ") { out.append(" ") }
                previous = nil
                continue
            }
            if let previous {
                let boundary = (previous.isLowercase && character.isUppercase)
                    || (previous.isLetter && character.isNumber)
                    || (previous.isNumber && character.isLetter)
                if boundary, !out.hasSuffix(" ") { out.append(" ") }
            }
            out.append(character)
            previous = character
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces a file's row in the v2 index (name, plus title and text if read).
    private func indexV2(path: String, title: String?, headings: String? = nil, text: String) {
        guard v2Ready, let database else { return }
        let name = Self.searchableName(path)
        deleteV2(path: path)
        var insert: OpaquePointer?
        defer { sqlite3_finalize(insert) }
        if sqlite3_prepare_v2(database,
                              "INSERT INTO search_fts (name, title, headings, text, path) VALUES (?, ?, ?, ?, ?)",
                              -1, &insert, nil) == SQLITE_OK {
            SQLite.bind(insert, 1, name)
            SQLite.bind(insert, 2, title ?? "")
            SQLite.bind(insert, 3, headings ?? "")
            SQLite.bind(insert, 4, text)
            SQLite.bind(insert, 5, path)
            sqlite3_step(insert)
        }
        var trigram: OpaquePointer?
        defer { sqlite3_finalize(trigram) }
        if sqlite3_prepare_v2(database, "INSERT INTO names_trigram (name, path) VALUES (?, ?)",
                              -1, &trigram, nil) == SQLITE_OK {
            SQLite.bind(trigram, 1, (path as NSString).lastPathComponent)
            SQLite.bind(trigram, 2, path)
            sqlite3_step(trigram)
        }
    }

    private func deleteV2(path: String) {
        guard v2Ready, let database else { return }
        for table in ["search_fts", "names_trigram"] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "DELETE FROM \(table) WHERE path = ?",
                                     -1, &statement, nil) == SQLITE_OK else { continue }
            SQLite.bind(statement, 1, path)
            sqlite3_step(statement)
        }
    }

    /// Records files in the usual folders, read or not, so names are searchable.
    /// A renamed or moved file (same inode) keeps its text and vectors.
    func recordFiles(_ entries: [(path: String, modified: Date?, size: Int?)]) {
        open()
        guard v2Ready, let database, !entries.isEmpty else { return }
        SQLite.exec(database, "BEGIN")
        // One prepared lookup reused for every file: most are unchanged, and
        // for those this is the only work done.
        var exists: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT mtime FROM files WHERE path = ?", -1, &exists, nil)
        defer { sqlite3_finalize(exists) }
        for entry in entries {
            sqlite3_reset(exists)
            SQLite.bind(exists, 1, entry.path)
            let known = sqlite3_step(exists) == SQLITE_ROW ? sqlite3_column_double(exists, 0) : nil
            let stamp = entry.modified?.timeIntervalSince1970 ?? 0
            if let known, abs(known - stamp) < 1 { continue }   // unchanged: nothing to do

            // New or changed: only now ask the disk for its identity.
            let inode = (try? FileManager.default.attributesOfItem(atPath: entry.path))
                .flatMap { ($0[.systemFileNumber] as? NSNumber)?.uint64Value }
            // Same inode, old path gone, same date: the same file renamed.
            if known == nil, let inode, let old = pathWithInode(inode, other: entry.path),
               !FileManager.default.fileExists(atPath: old.path),
               abs(old.mtime - stamp) < 1 {
                rename(from: old.path, to: entry.path)
            }

            var upsert: OpaquePointer?
            let sql = """
                INSERT INTO files (path, name, kind, folder, size, mtime, seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET name = excluded.name, kind = excluded.kind, size = excluded.size,
                    mtime = excluded.mtime, seen_at = excluded.seen_at
                """
            if sqlite3_prepare_v2(database, sql, -1, &upsert, nil) == SQLITE_OK {
                let url = URL(fileURLWithPath: entry.path)
                SQLite.bind(upsert, 1, entry.path)
                SQLite.bind(upsert, 2, url.lastPathComponent)
                SQLite.bind(upsert, 3, url.pathExtension.lowercased())
                SQLite.bind(upsert, 4, url.deletingLastPathComponent().path)
                sqlite3_bind_int64(upsert, 5, Int64(entry.size ?? 0))
                sqlite3_bind_double(upsert, 6, stamp)
                sqlite3_bind_double(upsert, 7, Date.now.timeIntervalSince1970)
                sqlite3_step(upsert)
            }
            sqlite3_finalize(upsert)
            if let inode {
                var identity: OpaquePointer?
                if sqlite3_prepare_v2(database, "UPDATE files SET inode = ? WHERE path = ?", -1, &identity, nil) == SQLITE_OK {
                    sqlite3_bind_int64(identity, 1, Int64(bitPattern: inode))
                    SQLite.bind(identity, 2, entry.path)
                    sqlite3_step(identity)
                }
                sqlite3_finalize(identity)
            }
            // Name-only until it's read — unless we already hold its text.
            if storedMtime(path: entry.path, table: "documents") == nil {
                indexV2(path: entry.path, title: nil, text: "")
            }
        }
        SQLite.exec(database, "COMMIT")
    }

    private func pathWithInode(_ inode: UInt64, other path: String) -> (path: String, mtime: Double)? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT path, mtime FROM files WHERE inode = ? AND path != ? LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, Int64(bitPattern: inode))
        SQLite.bind(statement, 2, path)
        guard sqlite3_step(statement) == SQLITE_ROW, let found = SQLite.string(statement, 0) else { return nil }
        return (found, sqlite3_column_double(statement, 1))
    }

    /// Moves everything known about `old` to `new`: the stored text, the
    /// index rows (re-made with the new name), and the meaning vectors.
    private func rename(from old: String, to new: String) {
        guard let database else { return }
        for sql in ["UPDATE documents SET path = ? WHERE path = ?",
                    "UPDATE unreadable SET path = ? WHERE path = ?",
                    "UPDATE files SET path = ?, name = ? WHERE path = ?"] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            SQLite.bind(statement, 1, new)
            if sql.contains("name = ?") {
                SQLite.bind(statement, 2, (new as NSString).lastPathComponent)
                SQLite.bind(statement, 3, old)
            } else {
                SQLite.bind(statement, 2, old)
            }
            sqlite3_step(statement)
        }
        deleteV2(path: old)
        let held = record(path: new, modified: nil, anyDate: true)
        indexV2(path: new, title: held?.title, headings: held?.headings, text: held?.text ?? "")
        ActivityLog.write(.search, "renamed in the index: \((old as NSString).lastPathComponent) → \((new as NSString).lastPathComponent)")
        Task {
            await SemanticIndex.shared.rename(from: old, to: new)
            // A photo's vector is quick to make again under its new name.
            await PhotoVectors.shared.forget(path: old)
        }
    }

    /// Drops files that were deleted from disk (not renamed — those were
    /// carried over in `recordFiles`), so search never offers a missing file.
    func removeVanished(seen: Set<String>) {
        open()
        guard v2Ready, let database else { return }
        // The disk ignores case: a path seen in other capitals is a duplicate row.
        let seenLowercased = Set(seen.map { $0.lowercased() })
        var gone = Set<String>()
        // `documents` too: a read file whose `files` row went first stayed
        // searchable at its old path.
        for table in ["files", "documents"] {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, "SELECT path FROM \(table)", -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let path = SQLite.string(statement, 0), !seen.contains(path) else { continue }
                    if seenLowercased.contains(path.lowercased()) || !FileManager.default.fileExists(atPath: path) {
                        gone.insert(path)
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        if !gone.isEmpty { ActivityLog.write(.search, "index: forgot \(gone.count) moved or doubled paths") }
        for path in gone { forget(path: path) }
    }

    /// Copies v1 documents into the v2 index, a batch at a time, so the first
    /// run after an update never stalls a search. Returns true when done.
    @discardableResult
    func migrateStep(limit: Int = 400) -> Bool {
        open()
        guard v2Ready, let database else { return false }
        if SQLite.userVersion(database) >= 2 { return true }
        let after = Int64(metaValue("v2_migrated_upto") ?? "0") ?? 0

        var statement: OpaquePointer?
        let sql = "SELECT id, path, title, text, headings FROM documents WHERE id > ? ORDER BY id LIMIT ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(statement, 1, after)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var rows: [(id: Int64, path: String, title: String?, text: String, headings: String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = SQLite.string(statement, 1) else { continue }
            rows.append((sqlite3_column_int64(statement, 0), path, SQLite.string(statement, 2),
                         SQLite.string(statement, 3) ?? "", SQLite.string(statement, 4)))
        }
        sqlite3_finalize(statement)

        guard let last = rows.last else {
            SQLite.exec(database, "PRAGMA user_version = 2")
            ActivityLog.write(.search, "content store: v2 index ready")
            return true
        }
        SQLite.exec(database, "BEGIN")
        for row in rows { indexV2(path: row.path, title: row.title, headings: row.headings, text: row.text) }
        setMeta("v2_migrated_upto", String(last.id))
        SQLite.exec(database, "COMMIT")
        return false
    }

    /// Search over what documents say (title, headings, text; not the name):
    /// exact phrase first, then any word. Nil until v2 is ready.
    private func searchV2(words: [String], limit: Int) -> [Hit]? {
        guard v2Ready, SQLite.userVersion(database) >= 2, let database else { return nil }
        var hits: [Hit] = []
        var seen = Set<String>()

        func run(_ sql: String, _ expression: String, phrase: Bool, boost: Double, allWords: Bool = false) {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
            SQLite.bind(statement, 1, expression)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = SQLite.string(statement, 0), !seen.contains(path) else { continue }
                seen.insert(path)
                let title = SQLite.string(statement, 1)
                hits.append(Hit(url: URL(fileURLWithPath: path),
                                title: (title?.isEmpty ?? true) ? nil : title,
                                score: -sqlite3_column_double(statement, 2) + boost,
                                phrase: phrase, allWords: phrase || allWords))
            }
        }
        let ranked = """
            SELECT path, title, bm25(search_fts, 0.0, 6.0, 4.0, 1.0)
            FROM search_fts WHERE search_fts MATCH ?
            ORDER BY bm25(search_fts, 0.0, 6.0, 4.0, 1.0) LIMIT ?
            """
        let cleaned = words.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }

        let content = "{title headings text} : "
        // 1. The words together, in order — a strong sign.
        if cleaned.count >= 2 {
            run(ranked, content + "\"" + cleaned.joined(separator: " ") + "\"", phrase: true, boost: 50)
        }
        // 2. Every word, anywhere in the document — the paper says "attention",
        // "all", "you" and "need"; a file of attention code mostly says one of
        // them, many times, which is all an any-word match can see.
        if cleaned.count >= 2 {
            // Prefix terms: query words arrive stemmed ("augment"), and the
            // prefix is what finds "augmented" and "augmentations".
            let every = cleaned.map { "\"\($0)\"*" }.joined(separator: " AND ")
            run(ranked, content + "(" + every + ")", phrase: false, boost: 25, allWords: true)
        }
        // Any of the words, each a prefix (half-typed or a stem).
        let terms = cleaned.map { "\"\($0)\"*" }
        run(ranked, content + "(" + terms.joined(separator: " OR ") + ")", phrase: false, boost: 0,
            allWords: cleaned.count == 1)
        return Array(hits.prefix(limit))
    }

    private func metaValue(_ key: String) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        SQLite.bind(statement, 1, key)
        return sqlite3_step(statement) == SQLITE_ROW ? SQLite.string(statement, 0) : nil
    }

    private func setMeta(_ key: String, _ value: String) {
        guard let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, key)
        SQLite.bind(statement, 2, value)
        sqlite3_step(statement)
    }

    // MARK: - Reading

    /// What we hold for this file, if its modification date still matches
    /// (within a second).
    func record(path: String, modified: Date?, anyDate: Bool = false) -> Record? {
        open()
        guard ready, let database else { return nil }
        let wanted = modified?.timeIntervalSince1970 ?? 0

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database,
                                 "SELECT text, title, mtime, headings FROM documents WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        SQLite.bind(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let stored = sqlite3_column_double(statement, 2)
        guard anyDate || abs(stored - wanted) < 1 else { return nil }
        // A document read before headings were collected is read again once, so
        // its headings make it into the index (NULL means "never looked").
        if !anyDate, !Self.isImage(path), sqlite3_column_type(statement, 3) == SQLITE_NULL {
            return nil
        }

        return Record(text: SQLite.string(statement, 0) ?? "", title: SQLite.string(statement, 1),
                      headings: SQLite.string(statement, 3))
    }

    /// Whether a current extraction exists (including "read, gave nothing"),
    /// without fetching the text.
    func isCurrent(path: String, modified: Date?) -> Bool {
        open()
        guard ready else { return false }
        let stamp = modified?.timeIntervalSince1970 ?? 0
        if let stored = storedMtime(path: path, table: "documents"), abs(stored - stamp) < 1 {
            // Read before headings were collected (NULL, not ''): once more,
            // so its headings get indexed. PDFs only — that's where they live.
            if !Self.isImage(path), headingsMissing(path: path) { return false }
            return true
        }
        if let stored = storedMtime(path: path, table: "unreadable"), abs(stored - stamp) < 1 {
            return true
        }
        return false
    }

    /// Which of these files are already read and current — one hop for a
    /// whole list, so the search sweep can skip what the indexer has done.
    func currentPaths(_ entries: [(path: String, modified: Date?)]) -> Set<String> {
        var out = Set<String>()
        for entry in entries where isCurrent(path: entry.path, modified: entry.modified) {
            out.insert(entry.path)
        }
        return out
    }

    /// Pictures in the usual folders not yet read at this version — the
    /// indexer's picture backlog. (Photos' own library is a package nobody
    /// reads, so it isn't counted.)
    func picturesLeft() -> Int {
        open()
        guard ready, v2Ready, let database else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT count(*) FROM files f
             WHERE f.kind IN ('png','jpg','jpeg','heic','webp') AND f.path NOT LIKE '%.photoslibrary/%'
               AND NOT EXISTS (SELECT 1 FROM documents d WHERE d.path = f.path AND abs(d.mtime - f.mtime) < 1)
               AND NOT EXISTS (SELECT 1 FROM unreadable u WHERE u.path = f.path AND abs(u.mtime - f.mtime) < 1)
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Photo captions

    /// A caption's place in a photo's text: first, with close words added.
    static func captionLine(_ caption: String) -> String {
        let words = Set(Tokens.of(caption))
        let related = Set(words.flatMap { TextExtractor.relatedLabels[$0] ?? [] }).subtracting(words).sorted()
        return "Photo: " + caption + (caption.hasSuffix(".") ? "" : ".")
            + (related.isEmpty ? "" : " Also: " + related.joined(separator: ", ") + ".") + "\n"
    }

    private func captionIfCurrent(path: String, stamp: Double) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT caption FROM documents WHERE path = ? AND abs(mtime - ?) < 1",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        SQLite.bind(statement, 1, path)
        sqlite3_bind_double(statement, 2, stamp)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SQLite.string(statement, 0)
    }

    private func aboutIfCurrent(path: String, stamp: Double) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT about FROM documents WHERE path = ? AND abs(mtime - ?) < 1",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        SQLite.bind(statement, 1, path)
        sqlite3_bind_double(statement, 2, stamp)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SQLite.string(statement, 0)
    }

    /// How a description sits in a document's text: first, like a photo's caption.
    static func aboutLine(_ about: String) -> String { "About: \(about).\n" }

    /// A document Pip hasn't described yet, with what the description is
    /// written from.
    struct Undescribed: Sendable {
        var path: String
        var modified: Date
        var title: String?
        var text: String
    }

    /// Documents (not pictures, not code) in the usual folders that have no
    /// description: the ones in `first` (surfaced by searches) first, then
    /// newest first.
    func undescribedDocuments(first: [String], limit: Int, onlyFirst: Bool = false) -> [Undescribed] {
        open()
        guard ready, let database else { return [] }
        var out: [Undescribed] = []
        func rows(_ sql: String, bind: (OpaquePointer?) -> Void) {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW, out.count < limit {
                guard let path = SQLite.string(statement, 0), !out.contains(where: { $0.path == path }) else { continue }
                out.append(Undescribed(path: path,
                                       modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                       title: SQLite.string(statement, 2), text: SQLite.string(statement, 3) ?? ""))
            }
        }
        let wanted = Self.describableSQL
        for path in first where out.count < limit {
            rows("SELECT path, mtime, title, text FROM documents WHERE path = ? AND \(wanted)") { SQLite.bind($0, 1, path) }
        }
        if out.count < limit, !onlyFirst {
            rows("SELECT path, mtime, title, text FROM documents WHERE \(wanted) ORDER BY mtime DESC LIMIT \(limit * 2)") { _ in }
        }
        return out
    }

    /// Not described yet, not a picture (those get captions), not code.
    private static let describableSQL: String = {
        let code = DirectScan.codeKinds.sorted().map { "lower(path) NOT LIKE '%.\($0)'" }.joined(separator: " AND ")
        return "about IS NULL AND mtime <> -1 AND NOT \(imageSQL) AND \(code)"
    }()

    func undescribedCount() -> Int {
        open()
        guard ready, let database else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT count(*) FROM documents WHERE \(Self.describableSQL)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Saves a description and puts it at the front of the document's
    /// searchable text. Returns the new text (for the meaning index), or nil
    /// if the file changed or went away meanwhile.
    func setAbout(path: String, modified: Date, about: String) -> (title: String?, text: String)? {
        open()
        guard ready, let database else { return nil }
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, "SELECT title, headings, text FROM documents WHERE path = ? AND abs(mtime - ?) < 1",
                                 -1, &read, nil) == SQLITE_OK else { return nil }
        SQLite.bind(read, 1, path)
        sqlite3_bind_double(read, 2, modified.timeIntervalSince1970)
        guard sqlite3_step(read) == SQLITE_ROW else { return nil }
        let title = SQLite.string(read, 0)
        let headings = SQLite.string(read, 1)
        var text = SQLite.string(read, 2) ?? ""
        if text.hasPrefix("About: "), let end = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: end)...])
        }
        if !about.isEmpty { text = Self.aboutLine(about) + text }
        var write: OpaquePointer?
        defer { sqlite3_finalize(write) }
        guard sqlite3_prepare_v2(database, "UPDATE documents SET about = ?, text = ? WHERE path = ?",
                                 -1, &write, nil) == SQLITE_OK else { return nil }
        SQLite.bind(write, 1, about)
        SQLite.bind(write, 2, text)
        SQLite.bind(write, 3, path)
        sqlite3_step(write)
        indexV2(path: path, title: title, headings: headings, text: text)
        return (title, text)
    }

    /// What's known about each file, for a result's subtitle and its group:
    /// Pip's description, its own title, a photo's caption, the start of its text.
    struct Note: Sendable {
        var about: String?
        var title: String?
        var caption: String?
        var opening: String
    }

    func notes(for paths: [String]) -> [String: Note] {
        open()
        guard ready, let database, !paths.isEmpty else { return [:] }
        var out: [String: Note] = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT about, title, caption, substr(text, 1, 400) FROM documents WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return [:] }
        for path in paths {
            sqlite3_reset(statement)
            SQLite.bind(statement, 1, path)
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            var opening = SQLite.string(statement, 3) ?? ""
            for prefix in ["About: ", "Photo: "] where opening.hasPrefix(prefix) {
                if let end = opening.firstIndex(of: "\n") { opening = String(opening[opening.index(after: end)...]) }
            }
            out[path] = Note(about: SQLite.string(statement, 0).flatMap { $0.isEmpty ? nil : $0 },
                             title: SQLite.string(statement, 1), caption: SQLite.string(statement, 2),
                             opening: opening)
        }
        return out
    }

    /// Photos read but not captioned: Desktop and Downloads first, newest
    /// first, screenshots last.
    private var uncaptionedSQL: String {
        let home = NSHomeDirectory().replacingOccurrences(of: "'", with: "''")
        let folders = ["Desktop", "Documents", "Downloads", "Pictures"]
            .map { "path LIKE '\(home)/\($0)/%'" }.joined(separator: " OR ")
        return "FROM documents WHERE caption IS NULL AND mtime <> -1 AND \(Self.imageSQL) "
            + "AND (\(folders)) AND path NOT LIKE '%.photoslibrary/%'"
    }

    func uncaptionedPhotos(limit: Int) -> [(path: String, modified: Date)] {
        open()
        guard ready, let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let screenshot = "(lower(path) LIKE '%/screenshot%' OR lower(path) LIKE '%/screen shot%' "
            + "OR lower(path) LIKE '%/cleanshot%')"
        let home = NSHomeDirectory().replacingOccurrences(of: "'", with: "''")
        let folder = "(CASE WHEN path LIKE '\(home)/Desktop/%' OR path LIKE '\(home)/Downloads/%' THEN 0 "
            + "WHEN path LIKE '\(home)/Documents/%' THEN 1 ELSE 2 END)"
        let sql = "SELECT path, mtime \(uncaptionedSQL) ORDER BY \(folder), \(screenshot), mtime DESC LIMIT \(limit)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var out: [(path: String, modified: Date)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = SQLite.string(statement, 0) else { continue }
            out.append((path, Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))))
        }
        return out
    }

    func uncaptionedCount() -> Int {
        open()
        guard ready, let database else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT count(*) \(uncaptionedSQL)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Saves a caption and puts it at the front of the photo's searchable
    /// text. Returns the new text (for the meaning index), or nil if the
    /// photo changed or went away meanwhile.
    func setCaption(path: String, modified: Date, caption: String) -> (title: String?, text: String)? {
        open()
        guard ready, let database else { return nil }
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, "SELECT title, headings, text FROM documents WHERE path = ? AND abs(mtime - ?) < 1",
                                 -1, &read, nil) == SQLITE_OK else { return nil }
        SQLite.bind(read, 1, path)
        sqlite3_bind_double(read, 2, modified.timeIntervalSince1970)
        guard sqlite3_step(read) == SQLITE_ROW else { return nil }
        let title = SQLite.string(read, 0)
        let headings = SQLite.string(read, 1)
        var text = SQLite.string(read, 2) ?? ""
        if text.hasPrefix("Photo: "), let end = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: end)...])
        }
        if !caption.isEmpty { text = Self.captionLine(caption) + text }

        var write: OpaquePointer?
        defer { sqlite3_finalize(write) }
        guard sqlite3_prepare_v2(database, "UPDATE documents SET caption = ?, text = ? WHERE path = ?",
                                 -1, &write, nil) == SQLITE_OK else { return nil }
        SQLite.bind(write, 1, caption)
        SQLite.bind(write, 2, text)
        SQLite.bind(write, 3, path)
        sqlite3_step(write)
        indexV2(path: path, title: title, headings: headings, text: text)
        return (title, text)
    }

    /// Every picture in Desktop, Downloads, Documents and Pictures, in the
    /// order to give it a photo vector: Desktop and Downloads first, then
    /// Documents, then Pictures; newest first within each.
    func pictureFiles() -> [(path: String, modified: Double)] {
        open()
        guard ready, v2Ready, let database else { return [] }
        let home = NSHomeDirectory().replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT path, mtime FROM files
             WHERE kind IN ('png','jpg','jpeg','heic','webp') AND path NOT LIKE '%.photoslibrary/%'
               AND (path LIKE '\(home)/Desktop/%' OR path LIKE '\(home)/Downloads/%'
                    OR path LIKE '\(home)/Documents/%' OR path LIKE '\(home)/Pictures/%')
             ORDER BY CASE WHEN path LIKE '\(home)/Desktop/%' OR path LIKE '\(home)/Downloads/%' THEN 0
                           WHEN path LIKE '\(home)/Documents/%' THEN 1 ELSE 2 END, mtime DESC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var out: [(path: String, modified: Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = SQLite.string(statement, 0) { out.append((path, sqlite3_column_double(statement, 1))) }
        }
        return out
    }

    /// Every path the store knows, with its name lowercased — for the search
    /// panel's instant name matches. Read when the panel opens, dropped when
    /// it closes.
    func knownNames() -> [(path: String, lower: String)] {
        open()
        guard v2Ready, let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT path FROM files", -1, &statement, nil) == SQLITE_OK else { return [] }
        var out: [(path: String, lower: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = SQLite.string(statement, 0) {
                out.append((path, (path as NSString).lastPathComponent.lowercased()))
            }
        }
        return out
    }

    /// SQL that matches a picture's path.
    private static let imageSQL = "(lower(path) LIKE '%.png' OR lower(path) LIKE '%.jpg' OR lower(path) LIKE '%.jpeg' "
        + "OR lower(path) LIKE '%.heic' OR lower(path) LIKE '%.webp')"

    /// Images are OCR'd and have no headings; re-reading them would be costly for nothing.
    private static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"].contains((path as NSString).pathExtension.lowercased())
    }

    private func headingsMissing(path: String) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT headings IS NULL FROM documents WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        SQLite.bind(statement, 1, path)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    private func storedMtime(path: String, table: String) -> Double? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT mtime FROM \(table) WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        SQLite.bind(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    /// Notes that this version of a file gave no text (retried when it changes).
    func markUnreadable(path: String, modified: Date?) {
        open()
        guard ready, let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT OR REPLACE INTO unreadable (path, mtime) VALUES (?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, path)
        sqlite3_bind_double(statement, 2, modified?.timeIntervalSince1970 ?? 0)
        sqlite3_step(statement)
        // A stored document that now reads as empty keeps its old text, and
        // stops being retried for headings on every search.
        SQLite.exec(database, "UPDATE documents SET headings = COALESCE(headings, '') WHERE path = '\(path.replacingOccurrences(of: "'", with: "''"))'")
        if storedMtime(path: path, table: "documents") == nil {
            indexV2(path: path, title: nil, text: "")     // still findable by name
        }
    }

    /// Everything read that matches, ranked by BM25.
    func search(words: [String], limit: Int = 60) -> [Hit] {
        open()
        guard ready, let database, !words.isEmpty else { return [] }
        if let v2 = searchV2(words: words, limit: limit) { return v2 }
        guard let expression = matchExpression(words) else { return [] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT d.path, d.title, bm25(documents_fts)
            FROM documents_fts
            JOIN documents d ON d.id = documents_fts.rowid
            WHERE documents_fts MATCH ?
            ORDER BY bm25(documents_fts)
            LIMIT ?
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        SQLite.bind(statement, 1, expression)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = SQLite.string(statement, 0) else { continue }
            // FTS5 returns bm25 as a negative number, most relevant most
            // negative, because it sorts ascending by default. Flip it so the
            // rest of the codebase's "larger is better" holds.
            hits.append(Hit(url: URL(fileURLWithPath: path),
                            title: SQLite.string(statement, 1),
                            score: -sqlite3_column_double(statement, 2)))
        }
        return hits
    }

    /// One stored document, for walking the whole store in order.
    struct Row: Sendable {
        var id: Int64
        var path: String
        var modified: Date
        var title: String?
        var text: String
    }

    /// A page of stored documents after a row id (for the semantic catch-up).
    func rows(after id: Int64, limit: Int = 100) -> [Row] {
        open()
        guard ready, let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id, path, mtime, title, text FROM documents WHERE id > ? ORDER BY id LIMIT ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var out: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = SQLite.string(statement, 1) else { continue }
            out.append(Row(id: sqlite3_column_int64(statement, 0),
                           path: path,
                           modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                           title: SQLite.string(statement, 3),
                           text: SQLite.string(statement, 4) ?? ""))
        }
        return out
    }

    /// A MATCH expression that can't be a syntax error: each term quoted, as a
    /// prefix, ORed (recall here, precision in the ranker).
    private func matchExpression(_ words: [String]) -> String? {
        // No length filter: `Tokens.of` decides what a word is (digits count).
        let terms = words.compactMap { word -> String? in
            // Strictly a quoting step: FTS5 treats `-`, `*`, `:`, `^`, `"` and
            // `(` as operators, so anything that isn't alphanumeric has to go
            // before the term is wrapped in quotes as a literal.
            let cleaned = word.filter { $0.isLetter || $0.isNumber }
            guard !cleaned.isEmpty else { return nil }
            return "\"\(cleaned)\"*"
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    // MARK: - Writing

    /// Stores an extraction (upsert: a later, deeper read replaces it).
    func store(path: String, modified: Date?, title: String?, headings: String? = nil, text: String) {
        open()
        guard ready, let database, !text.isEmpty, !DirectScan.isExcluded(path) else { return }
        // A photo read again at the same date keeps its caption; a changed
        // one is captioned again.
        let caption = captionIfCurrent(path: path, stamp: modified?.timeIntervalSince1970 ?? 0)
        let about = aboutIfCurrent(path: path, stamp: modified?.timeIntervalSince1970 ?? 0)
        var text = text
        if let caption, !caption.isEmpty, !text.hasPrefix("Photo: ") { text = Self.captionLine(caption) + text }
        if let about, !about.isEmpty, !text.hasPrefix("About: ") { text = Self.aboutLine(about) + text }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO documents (path, mtime, title, text, read_at, headings, caption, about)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                mtime = excluded.mtime,
                title = excluded.title,
                text = excluded.text,
                read_at = excluded.read_at,
                headings = excluded.headings,
                caption = excluded.caption,
                about = excluded.about
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, path)
        sqlite3_bind_double(statement, 2, modified?.timeIntervalSince1970 ?? 0)
        if let title { SQLite.bind(statement, 3, title) } else { sqlite3_bind_null(statement, 3) }
        SQLite.bind(statement, 4, text)
        sqlite3_bind_double(statement, 5, Date.now.timeIntervalSince1970)
        SQLite.bind(statement, 6, headings ?? "")
        if let caption { SQLite.bind(statement, 7, caption) } else { sqlite3_bind_null(statement, 7) }
        if let about { SQLite.bind(statement, 8, about) } else { sqlite3_bind_null(statement, 8) }
        sqlite3_step(statement)
        indexV2(path: path, title: title, headings: headings, text: text)

        // It has text now, so it's no longer one of the unreadable ones.
        var cleanup: OpaquePointer?
        defer { sqlite3_finalize(cleanup) }
        guard sqlite3_prepare_v2(database, "DELETE FROM unreadable WHERE path = ?",
                                 -1, &cleanup, nil) == SQLITE_OK else { return }
        SQLite.bind(cleanup, 1, path)
        sqlite3_step(cleanup)
    }

    /// Notes that a row was useful, so pruning keeps what gets used.
    func touch(path: String) {
        open()
        guard ready, let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "UPDATE documents SET read_at = ? WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(statement, 1, Date.now.timeIntervalSince1970)
        SQLite.bind(statement, 2, path)
        sqlite3_step(statement)
    }

    /// Drops a file we can no longer read or that has gone away.
    func forget(path: String) {
        open()
        guard ready, let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "DELETE FROM documents WHERE path = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, path)
        sqlite3_step(statement)
        deleteV2(path: path)
        if v2Ready { SQLite.exec(database, "DELETE FROM files WHERE path = '\(path.replacingOccurrences(of: "'", with: "''"))'") }
        // The vectors describe the same file, so they go with it.
        Task {
            await SemanticIndex.shared.forget(path: path)
            await PhotoVectors.shared.forget(path: path)
        }
    }

    // MARK: - Housekeeping

    /// Drops the oldest-unused rows down to a count, noting them in
    /// `unreadable` so they aren't re-read. Pictures are never dropped.
    func prune(to keep: Int = 20_000) {
        open()
        guard ready else { return }
        let overflow = "SELECT id FROM documents WHERE NOT \(Self.imageSQL) "
            + "ORDER BY read_at DESC LIMIT -1 OFFSET \(keep)"
        SQLite.exec(database, "INSERT OR REPLACE INTO unreadable (path, mtime) "
                    + "SELECT path, mtime FROM documents WHERE id IN (\(overflow))")
        SQLite.exec(database, "DELETE FROM documents WHERE id IN (\(overflow))")
        // Pruned documents fall back to name-only in the v2 index.
        if v2Ready {
            SQLite.exec(database, """
                UPDATE search_fts SET text = '', title = ''
                WHERE text != '' AND path NOT IN (SELECT path FROM documents)
                """)
        }
    }

    /// For diagnostics: how much we've learned, and how big it got.
    func summary() -> String {
        open()
        guard ready, let database else {
            return "content store unavailable — extraction is not being cached"
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT count(*), sum(length(text)) FROM documents",
                                 -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return "content store empty" }
        let count = Int(sqlite3_column_int64(statement, 0))
        let bytes = Int(sqlite3_column_int64(statement, 1))
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(count) documents cached, \(bytes / 1024) KB of text, "
             + "database \(size / 1024) KB"
    }
}
