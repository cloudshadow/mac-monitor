import CSQLite
import Darwin
import Foundation
import MonitorCore

/// The containing store serializes all calls, including progress handlers and checkpoints.
final class SQLite {
  var handle: OpaquePointer?
  init(path: String) throws {
    var info = stat()
    if lstat(path, &info) == 0 && (info.st_mode & S_IFMT != S_IFREG || info.st_uid != geteuid()) {
      throw APIError(503, "unsafeDataPath")
    }
    guard
      sqlite3_open_v2(
        path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK
    else {
      if let handle { sqlite3_close(handle) }
      self.handle = nil
      throw APIError(503, "databaseUnavailable")
    }
    chmod(path, 0o600)
    do {
      try exec(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA foreign_keys=ON; PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA busy_timeout=50; PRAGMA wal_autocheckpoint=0;"
      )
    } catch {
      sqlite3_close(handle)
      handle = nil
      throw error
    }
  }
  deinit { if let handle { sqlite3_close(handle) } }
  func error() -> APIError {
    let code = sqlite3_errcode(handle)
    return APIError(
      503,
      code == SQLITE_INTERRUPT
        ? "queryBudgetExceeded" : code == SQLITE_FULL ? "diskFull" : "databaseUnavailable")
  }
  func exec(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try exec("COMMIT")
      return value
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }
  func statement(_ sql: String, _ args: [JSONValue]) throws -> OpaquePointer {
    var p: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &p, nil) == SQLITE_OK, let p else { throw error() }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, a) in args.enumerated() {
      let code: Int32
      switch a {
      case .string(let s): code = sqlite3_bind_text(p, Int32(i + 1), s, -1, transient)
      case .number(let n): code = sqlite3_bind_double(p, Int32(i + 1), n)
      case .bool(let b): code = sqlite3_bind_int(p, Int32(i + 1), b ? 1 : 0)
      case .null: code = sqlite3_bind_null(p, Int32(i + 1))
      default:
        sqlite3_finalize(p)
        throw APIError(400, "invalidParameter")
      }
      if code != SQLITE_OK {
        sqlite3_finalize(p)
        throw error()
      }
    }
    return p
  }
  func run(_ sql: String, _ args: [JSONValue] = []) throws {
    let p = try statement(sql, args)
    defer { sqlite3_finalize(p) }
    guard sqlite3_step(p) == SQLITE_DONE else { throw error() }
  }
  func rows(_ sql: String, _ args: [JSONValue] = [], limit: Int = 100_000) throws -> [[String:
    JSONValue]]
  {
    let p = try statement(sql, args)
    defer { sqlite3_finalize(p) }
    var rows: [[String: JSONValue]] = []
    while true {
      let result = sqlite3_step(p)
      if result == SQLITE_DONE { return rows }
      guard result == SQLITE_ROW else { throw error() }
      guard rows.count < limit else { throw APIError(503, "queryBudgetExceeded") }
      var row: [String: JSONValue] = [:]
      for col in 0..<sqlite3_column_count(p) {
        let name = String(cString: sqlite3_column_name(p, col))
        switch sqlite3_column_type(p, col) {
        case SQLITE_NULL: row[name] = .null
        case SQLITE_TEXT: row[name] = .string(String(cString: sqlite3_column_text(p, col)))
        default: row[name] = .number(sqlite3_column_double(p, col))
        }
      }
      rows.append(row)
    }
  }
  func checkpoint() throws {
    guard sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK
    else { throw error() }
  }
  func backup(to path: String) throws {
    var target: OpaquePointer?
    guard sqlite3_open(path, &target) == SQLITE_OK else {
      if let target { sqlite3_close(target) }
      throw error()
    }
    defer { sqlite3_close(target) }
    guard let backup = sqlite3_backup_init(target, "main", handle, "main") else { throw error() }
    let result = sqlite3_backup_step(backup, -1)
    sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE else { throw error() }
    chmod(path, 0o600)
  }
}
