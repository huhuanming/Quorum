import Foundation
import SQLite3

final class SQLiteSnapshotStore {
    private struct RuntimeSnapshot: Codable {
        var meetings: [Meeting]
    }

    private let databaseURL: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var connection: OpaquePointer?
        if sqlite3_open(databaseURL.path, &connection) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            throw SQLiteStoreError.openFailed(message)
        }

        self.db = connection
        sqlite3_busy_timeout(connection, 3_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS quorum_state (
                key TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
    }

    deinit {
        sqlite3_close(db)
    }

    func loadMeetings() throws -> [Meeting] {
        guard let db else { throw SQLiteStoreError.closed }
        let sql = "SELECT payload FROM quorum_state WHERE key = ? LIMIT 1"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, "meetings", -1, sqliteTransient())

        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            return []
        }
        guard step == SQLITE_ROW else {
            throw lastError(db)
        }

        guard let bytes = sqlite3_column_blob(statement, 0) else {
            return []
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else {
            return []
        }

        let payload = Data(bytes: bytes, count: count)
        let snapshot = try decoder.decode(RuntimeSnapshot.self, from: payload)
        return snapshot.meetings
    }

    func saveMeetings(_ meetings: [Meeting], updatedAt: Date) throws {
        guard let db else { throw SQLiteStoreError.closed }

        let payload = try encoder.encode(RuntimeSnapshot(meetings: meetings))
        let sql =
            "INSERT INTO quorum_state(key, payload, updated_at) VALUES(?, ?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, "meetings", -1, sqliteTransient())
        _ = payload.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, 2, rawBuffer.baseAddress, Int32(payload.count), sqliteTransient())
        }
        sqlite3_bind_double(statement, 3, updatedAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw SQLiteStoreError.closed }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else {
                message = "Unknown SQLite exec error"
            }
            throw SQLiteStoreError.execFailed(message)
        }
    }

    private func lastError(_ db: OpaquePointer?) -> SQLiteStoreError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return .queryFailed(message)
    }

    private func sqliteTransient() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

enum SQLiteStoreError: Error, LocalizedError {
    case openFailed(String)
    case execFailed(String)
    case queryFailed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "SQLite open failed for database: \(message)"
        case .execFailed(let message):
            return "SQLite exec failed: \(message)"
        case .queryFailed(let message):
            return "SQLite query failed: \(message)"
        case .closed:
            return "SQLite database is closed"
        }
    }
}
