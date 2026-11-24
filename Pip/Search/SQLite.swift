import Foundation
import SQLite3

/// Thin C wrappers shared by the on-disk stores, and their migrations:
/// each database lists its layout changes, run once in order (`migrate`).
enum SQLite {

    static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    static func bind(_ statement: OpaquePointer?, _ index: Int32, blob bytes: UnsafeRawBufferPointer) {
        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
    }

    static func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    @discardableResult
    static func exec(_ database: OpaquePointer?, _ sql: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    static func userVersion(_ database: OpaquePointer?) -> Int {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// One change to a database's layout. `apply` must be harmless on a
    /// database that already has it (a column that's there, a fix done).
    struct Migration {
        let version: Int
        let name: String
        let apply: (OpaquePointer?) -> Bool
    }

    /// Runs the migrations not done yet, in order, each once and inside a
    /// transaction; `user_version` records the last one done. The first that
    /// fails is rolled back and logged, and the rest wait for the next launch:
    /// the database carries on in the layout it had. Returns the version.
    @discardableResult
    static func migrate(_ database: OpaquePointer?, _ label: String, _ migrations: [Migration]) -> Int {
        guard let database else { return 0 }
        var done = userVersion(database)
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > done {
            exec(database, "BEGIN")
            if migration.apply(database), exec(database, "PRAGMA user_version = \(migration.version)") {
                exec(database, "COMMIT")
                done = migration.version
                ActivityLog.write(.system, "\(label): migration \(migration.version) (\(migration.name)) done")
            } else {
                let message = String(cString: sqlite3_errmsg(database))
                exec(database, "ROLLBACK")
                ActivityLog.write(.error, "\(label): migration \(migration.version) (\(migration.name)) failed — \(message); "
                                  + "carrying on with version \(done)")
                break
            }
        }
        return done
    }

    static func hasColumn(_ database: OpaquePointer?, _ table: String, _ column: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            if string(statement, 1) == column { return true }
        }
        return false
    }

    /// Adds a column unless it's there already. True when it's there after.
    static func addColumn(_ database: OpaquePointer?, _ table: String, _ column: String, _ definition: String) -> Bool {
        hasColumn(database, table, column) || exec(database, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    /// A `meta (key, value)` table's value, for stores that keep one.
    static func meta(_ database: OpaquePointer?, _ key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        bind(statement, 1, key)
        return sqlite3_step(statement) == SQLITE_ROW ? string(statement, 0) : nil
    }

    @discardableResult
    static func setMeta(_ database: OpaquePointer?, _ key: String, _ value: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        bind(statement, 1, key)
        bind(statement, 2, value)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// The stores are rebuildable by definition, so backing them up is
    /// wasted space in every Time Machine snapshot.
    static func excludeFromBackup(_ location: URL) {
        var url = location
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// SQLITE_TRANSIENT: SQLite copies the bound value. Computed (a C function
    /// pointer isn't Sendable).
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
