import CSQLite
import Foundation

/// Owned by the benchmark's one serial database queue, never by an NIO event loop.
public final class ProbeDatabase {
    private var db: OpaquePointer?
    public static var version: String { String(cString: sqlite3_libversion()) }
    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }; db = nil
            throw ProbeError.database(message)
        }
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA foreign_keys=ON; PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA busy_timeout=50; PRAGMA wal_autocheckpoint=0;")
            try execute("CREATE TABLE IF NOT EXISTS probe_minute (segment TEXT NOT NULL, minute INTEGER NOT NULL, count INTEGER NOT NULL, covered_ms REAL NOT NULL, weighted_sum REAL NOT NULL, minimum REAL NOT NULL, maximum REAL NOT NULL, PRIMARY KEY(segment,minute)) WITHOUT ROWID;")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ProbeError.database(String(cString: sqlite3_errmsg(db))) }
    }
    public func commit(segment: UUID, minute: Int64, count: Int, coveredMs: Double, weightedSum: Double, minimum: Double, maximum: Double) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO probe_minute VALUES(?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else {
                throw ProbeError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, segment.uuidString, -1, transient)
            sqlite3_bind_int64(statement, 2, minute)
            sqlite3_bind_int(statement, 3, Int32(count))
            sqlite3_bind_double(statement, 4, coveredMs)
            sqlite3_bind_double(statement, 5, weightedSum)
            sqlite3_bind_double(statement, 6, minimum)
            sqlite3_bind_double(statement, 7, maximum)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ProbeError.database(String(cString: sqlite3_errmsg(db))) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func checkpoint() throws {
        guard sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) == SQLITE_OK else {
            throw ProbeError.database(String(cString: sqlite3_errmsg(db)))
        }
    }
    public func rowCount() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM probe_minute", -1, &statement, nil) == SQLITE_OK else {
            throw ProbeError.database("count prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ProbeError.database("count failed") }
        return Int(sqlite3_column_int(statement, 0))
    }
}
