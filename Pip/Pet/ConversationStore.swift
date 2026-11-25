import Foundation
import SQLite3

/// Everything said with Pip, one session per day, in `conversations.db`.
/// Private results kept by size only, others capped. One serial queue keeps
/// the order.
final class ConversationStore: @unchecked Sendable {

    static let shared = ConversationStore()

    private let queue = DispatchQueue(label: "DynamicNotch.ConversationStore", qos: .utility)
    private var database: OpaquePointer?
    private let location = AppFolders.support.appendingPathComponent("conversations.db")

    /// Results kept by size only, and the cap on the rest.
    private static let privateTools: Set<String> = ["read_clipboard", "look_at_screen"]
    private static let resultCap = 2_000

    /// "2026-11-07", local time: the session a moment belongs to.
    static func day(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Writing

    /// Adds one message to the session for `day`, making the session if new.
    func append(_ message: [String: Any], day: String) {
        let role = message["role"] as? String ?? ""
        let tool = message["tool_name"] as? String
        let untrusted = message["untrusted"] as? Bool == true
        var content = message["content"] as? String ?? ""
        let words = content.split(whereSeparator: \.isWhitespace).count
        if untrusted {
            content = "(copied text, \(words) words)"
        } else if role == "tool", let tool, Self.privateTools.contains(tool), !content.hasPrefix("Not done:") {
            // (A refusal says nothing private, and stored by size it read as
            // a screen result that never happened.)
            content = "(\(tool.replacingOccurrences(of: "_", with: " ")) result, \(words) words)"
        } else if role == "tool", content.count > Self.resultCap {
            content = String(content.prefix(Self.resultCap)) + "…"
        }
        var calls: String?
        if let toolCalls = message["tool_calls"], JSONSerialization.isValidJSONObject(toolCalls),
           let data = try? JSONSerialization.data(withJSONObject: toolCalls) {
            calls = String(decoding: data, as: UTF8.self)
        }
        let now = Date().timeIntervalSince1970
        queue.async { [self] in
            guard open(), let session = session(for: day, create: true) else { return }
            run("INSERT INTO messages (session, at, role, content, tool_name, tool_calls, untrusted) VALUES (?, ?, ?, ?, ?, ?, ?)") {
                sqlite3_bind_int64($0, 1, session)
                sqlite3_bind_double($0, 2, now)
                SQLite.bind($0, 3, role)
                SQLite.bind($0, 4, content)
                if let tool { SQLite.bind($0, 5, tool) } else { sqlite3_bind_null($0, 5) }
                if let calls { SQLite.bind($0, 6, calls) } else { sqlite3_bind_null($0, 6) }
                sqlite3_bind_int($0, 7, untrusted ? 1 : 0)
            }
        }
    }

    func setSummary(_ summary: String, day: String) {
        queue.async { [self] in
            guard open() else { return }
            run("UPDATE sessions SET summary = ?, summarized_at = ? WHERE day = ?") {
                SQLite.bind($0, 1, summary)
                sqlite3_bind_double($0, 2, Date().timeIntervalSince1970)
                SQLite.bind($0, 3, day)
            }
        }
    }

    /// The menu's "Forget This Conversation": today's session only.
    func deleteSession(day: String) {
        queue.async { [self] in
            guard open() else { return }
            run("DELETE FROM messages WHERE session IN (SELECT id FROM sessions WHERE day = ?)") { SQLite.bind($0, 1, day) }
            run("DELETE FROM sessions WHERE day = ?") { SQLite.bind($0, 1, day) }
        }
    }

    /// The menu's "Delete All Saved Conversations…".
    func deleteAll() {
        queue.async { [self] in
            guard open() else { return }
            SQLite.exec(database, "DELETE FROM messages; DELETE FROM sessions; VACUUM;")
        }
    }

    // MARK: - Reading

    /// A session's messages in order, rebuilt as the model sees them.
    func messages(day: String) -> [[String: Any]] {
        queue.sync {
            guard open() else { return [] }
            var out: [[String: Any]] = []
            each("""
                SELECT m.role, m.content, m.tool_name, m.tool_calls, m.untrusted, m.disputed FROM messages m
                JOIN sessions s ON s.id = m.session WHERE s.day = ? ORDER BY m.id
                """, bind: { SQLite.bind($0, 1, day) }) { row in
                var message: [String: Any] = ["role": SQLite.string(row, 0) ?? "", "content": SQLite.string(row, 1) ?? ""]
                if let tool = SQLite.string(row, 2) { message["tool_name"] = tool }
                if let calls = SQLite.string(row, 3), let parsed = try? JSONSerialization.jsonObject(with: Data(calls.utf8)) {
                    message["tool_calls"] = parsed
                }
                if sqlite3_column_int(row, 4) == 1 { message["untrusted"] = true }
                if sqlite3_column_int(row, 5) == 1 { message["disputed"] = true }
                out.append(message)
            }
            return out
        }
    }

    /// The last day before `day` that has messages, and its summary if one
    /// was written after its last message (an older one would miss the end).
    func previousSession(before day: String) -> (day: String, summary: String?)? {
        queue.sync {
            guard open() else { return nil }
            var found: (String, String?)?
            each("""
                SELECT s.day, CASE WHEN s.summarized_at >= (SELECT max(at) FROM messages WHERE session = s.id)
                    THEN s.summary END FROM sessions s WHERE s.day < ?
                AND EXISTS (SELECT 1 FROM messages m WHERE m.session = s.id) ORDER BY s.day DESC LIMIT 1
                """, bind: { SQLite.bind($0, 1, day) }) { row in
                found = (SQLite.string(row, 0) ?? "", SQLite.string(row, 1))
            }
            return found.map { (day: $0.0, summary: $0.1) }
        }
    }

    /// Matching messages from earlier sessions, newest first: date, who, text.
    func search(_ words: [String], since: Date? = nil, until: Date? = nil, limit: Int = 6)
        -> [(day: String, role: String, text: String)] {
        let terms = words.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let expression = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        return queue.sync {
            guard open() else { return [] }
            var out: [(String, String, String)] = []
            // The best matches, shown newest first: the latest answer about
            // something is usually the one that stood.
            each("""
                SELECT day, role, text FROM (
                    SELECT s.day AS day, m.role AS role, snippet(messages_fts, 0, '', '', '…', 24) AS text, m.at AS at
                    FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid JOIN sessions s ON s.id = m.session
                    WHERE messages_fts MATCH ? AND m.at >= ? AND m.at <= ? AND m.disputed = 0
                    ORDER BY bm25(messages_fts) LIMIT ?)
                ORDER BY at DESC
                """, bind: {
                    SQLite.bind($0, 1, expression)
                    sqlite3_bind_double($0, 2, since?.timeIntervalSince1970 ?? 0)
                    sqlite3_bind_double($0, 3, until?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)
                    sqlite3_bind_int($0, 4, Int32(limit))
                }) { row in
                out.append((SQLite.string(row, 0) ?? "", SQLite.string(row, 1) ?? "", SQLite.string(row, 2) ?? ""))
            }
            return out.map { (day: $0.0, role: $0.1, text: $0.2) }
        }
    }

    /// Past requests holding the same words: the files Pip used and whether
    /// the user confirmed them. Newest first.
    enum Verdict { case confirmed, wrong, unknown }

    /// What a reply says about the answer before it: "wrong", "no, it's…"
    /// or "correct", "thanks". Whole words only.
    static func verdict(of reply: String) -> Verdict {
        let words = reply.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        // "wrong" anywhere; "no", "not" only as the reply opens ("no, it's the
        // 26th") — "I'm not sure, can you find…" is a new question.
        let opening = Set(words.prefix(3))
        if words.contains("wrong") || words.contains("incorrect") || !opening.isDisjoint(with: ["no", "nope", "not"]) {
            return .wrong
        }
        if !opening.isDisjoint(with: ["correct", "yes", "right", "thanks", "thank", "perfect", "exactly"]) { return .confirmed }
        return .unknown
    }

    /// The latest answer Pip gave in `day`'s session was wrong, the user says.
    func disputeLastAnswer(day: String) {
        queue.async { [self] in
            guard open() else { return }
            run("""
                UPDATE messages SET disputed = 1 WHERE id = (SELECT max(m.id) FROM messages m JOIN sessions s
                ON s.id = m.session WHERE s.day = ? AND m.role = 'assistant' AND m.content != '')
                """) { SQLite.bind($0, 1, day) }
        }
    }

    func remembered(_ words: [String], before: Date) -> [(path: String, day: String, verdict: Verdict)] {
        let terms = words.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let expression = terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
        return queue.sync {
            guard open() else { return [] }
            var turns: [(id: Int64, session: Int64, day: String)] = []
            each("""
                SELECT m.id, m.session, s.day FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
                JOIN sessions s ON s.id = m.session
                WHERE messages_fts MATCH ? AND m.role = 'user' AND m.untrusted = 0 AND m.at < ?
                ORDER BY m.at DESC LIMIT 10
                """, bind: {
                    SQLite.bind($0, 1, expression)
                    sqlite3_bind_double($0, 2, before.timeIntervalSince1970)
                }) { row in
                turns.append((sqlite3_column_int64(row, 0), sqlite3_column_int64(row, 1), SQLite.string(row, 2) ?? ""))
            }
            var out: [(path: String, day: String, verdict: Verdict)] = []
            for turn in turns {
                var paths: [String] = []
                var next: String?
                each("SELECT role, content, tool_name, tool_calls FROM messages WHERE session = ? AND id > ? ORDER BY id LIMIT 40",
                     bind: {
                        sqlite3_bind_int64($0, 1, turn.session)
                        sqlite3_bind_int64($0, 2, turn.id)
                     }) { row in
                    guard next == nil else { return }
                    let role = SQLite.string(row, 0) ?? ""
                    if role == "user" { next = (SQLite.string(row, 1) ?? "").lowercased(); return }
                    if let calls = SQLite.string(row, 3),
                       let parsed = try? JSONSerialization.jsonObject(with: Data(calls.utf8)) as? [[String: Any]] {
                        for call in parsed {
                            let function = call["function"] as? [String: Any]
                            if ["look_at_photo", "open_file", "reveal_file"].contains(function?["name"] as? String ?? ""),
                               let path = (function?["arguments"] as? [String: Any])?["path"] as? String {
                                paths.append(path)
                            }
                        }
                    }
                    // A search's top file counts when nothing was looked at.
                    if role == "tool", SQLite.string(row, 2) == "find_files", paths.isEmpty,
                       let first = (SQLite.string(row, 1) ?? "").split(separator: "\n").first,
                       let range = first.range(of: " — path: ") {
                        let rest = first[range.upperBound...]
                        paths.append(String(rest[..<(rest.range(of: " (modified")?.lowerBound ?? rest.endIndex)]))
                    }
                }
                let verdict = Self.verdict(of: next ?? "")
                // The last file of the turn is the one the answer was about.
                if let path = paths.last, !out.contains(where: { $0.path == path }) {
                    out.append((path, turn.day, verdict))
                }
            }
            return out
        }
    }

    // MARK: - SQLite (on the queue)

    private func open() -> Bool {
        if database != nil { return true }
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(location.path, &database) == SQLITE_OK else {
            database = nil
            ActivityLog.write(.error, "conversations: couldn't open conversations.db")
            return false
        }
        SQLite.exec(database, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY, day TEXT UNIQUE NOT NULL,
                started REAL NOT NULL, summary TEXT, summarized_at REAL);
            CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, session INTEGER NOT NULL REFERENCES sessions(id),
                at REAL NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, tool_name TEXT, tool_calls TEXT,
                untrusted INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS messages_session ON messages(session, id);
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(content, content='messages', content_rowid='id');
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content); END;
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content) VALUES ('delete', old.id, old.content); END;
            """)
        SQLite.migrate(database, "conversations.db", [
            // Added 2026-11-07: answers the user said were wrong.
            SQLite.Migration(version: 1, name: "messages.disputed") {
                SQLite.addColumn($0, "messages", "disputed", "INTEGER NOT NULL DEFAULT 0")
            },
        ])
        return true
    }

    private func session(for day: String, create: Bool) -> Int64? {
        var id: Int64?
        each("SELECT id FROM sessions WHERE day = ?", bind: { SQLite.bind($0, 1, day) }) { id = sqlite3_column_int64($0, 0) }
        if id == nil, create {
            run("INSERT INTO sessions (day, started) VALUES (?, ?)") {
                SQLite.bind($0, 1, day)
                sqlite3_bind_double($0, 2, Date().timeIntervalSince1970)
            }
            id = sqlite3_last_insert_rowid(database)
        }
        return id
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(statement)
        sqlite3_step(statement)
    }

    private func each(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }
}
