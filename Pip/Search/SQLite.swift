import Foundation
import SQLite3

/// Thin C wrappers shared by the two on-disk stores, `ContentStore` and
/// `SemanticIndex`. Each used to carry its own identical copy.
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
