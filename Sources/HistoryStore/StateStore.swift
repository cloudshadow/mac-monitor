import Darwin
import Foundation
import MonitorCore

public struct Account: Sendable {
  public let username: String, passwordHash: String
  public let epoch: Int64
}

public final class StateStore: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var db: SQLite?
  private let recoveryFlag = Locked(false)
  public var recoveryRequired: Bool { recoveryFlag.withLock { $0 } }
  public let path: String
  public init(path: String) {
    self.path = path
    let existed = FileManager.default.fileExists(atPath: path)
    do {
      let connection = try SQLite(path: path)
      if existed {
        guard try connection.rows("PRAGMA quick_check").first?["quick_check"]?.string == "ok",
          try connection.rows("PRAGMA user_version").first?["user_version"]?.number == 1,
          try connection.rows("PRAGMA application_id").first?["application_id"]?.number
            == 1_129_141_070
        else { throw APIError(503, "recoveryRequired") }
        _ = try connection.rows(
          "SELECT id,username,password_hash,auth_epoch,created_at,updated_at FROM account LIMIT 0")
        _ = try connection.rows(
          "SELECT id,label,token_hash,created_at,expires_at,revoked_at FROM device LIMIT 0")
        _ = try connection.rows("SELECT key,value FROM settings LIMIT 0")
      } else {
        try connection.transaction {
          try connection.exec(
            "CREATE TABLE account(id INTEGER PRIMARY KEY CHECK(id=1), username TEXT NOT NULL, password_hash TEXT NOT NULL, auth_epoch INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL); CREATE TABLE device(id TEXT PRIMARY KEY, label TEXT NOT NULL, token_hash TEXT UNIQUE NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL, revoked_at REAL); CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL); PRAGMA application_id=1129141070; PRAGMA user_version=1;"
          )
        }
      }
      db = connection
    } catch { recoveryFlag.withLock { $0 = true } }
  }
  private func access<T>(_ body: (SQLite) throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard let db, !recoveryRequired else { throw APIError(503, "recoveryRequired") }
    return try body(db)
  }
  /// Explicit owner recovery only. The damaged database is preserved; history is untouched.
  public func recover() throws {
    lock.lock()
    defer { lock.unlock() }
    guard recoveryRequired else { throw APIError(409, "recoveryNotRequired") }
    let backup = path + ".recovery"
    for suffix in ["", "-wal", "-shm"] {
      guard !FileManager.default.fileExists(atPath: backup + suffix) else {
        throw APIError(409, "recoveryBackupExists")
      }
    }
    db = nil
    for suffix in ["", "-wal", "-shm"] {
      if FileManager.default.fileExists(atPath: path + suffix) {
        try FileManager.default.moveItem(atPath: path + suffix, toPath: backup + suffix)
        chmod(backup + suffix, 0o600)
      }
    }
    let replacement = StateStore(path: path)
    guard !replacement.recoveryRequired, let connection = replacement.db else {
      throw APIError(503, "recoveryRequired")
    }
    db = connection
    replacement.db = nil
    recoveryFlag.withLock { $0 = false }
  }
  public func account() throws -> Account? {
    try access { db in
      guard
        let r = try db.rows("SELECT username,password_hash,auth_epoch FROM account WHERE id=1")
          .first
      else { return nil }
      guard let username = r["username"]?.string, let hash = r["password_hash"]?.string,
        let epoch = r["auth_epoch"]?.number
      else { throw APIError(503, "recoveryRequired") }
      return Account(username: username, passwordHash: hash, epoch: Int64(epoch))
    }
  }
  public func create(username: String, hash: String) throws {
    try access { db in
      try db.transaction {
        guard try db.rows("SELECT id FROM account").isEmpty else {
          throw APIError(409, "accountExists")
        }
        let now = Date().timeIntervalSince1970
        try db.run(
          "INSERT INTO account VALUES(1,?,?,1,?,?)",
          [.string(username), .string(hash), .number(now), .number(now)])
      }
    }
  }
  public func changePassword(hash: String) throws {
    try access { db in
      try db.transaction {
        guard try !db.rows("SELECT id FROM account").isEmpty else {
          throw APIError(409, "setupRequired")
        }
        try db.run(
          "UPDATE account SET password_hash=?,auth_epoch=auth_epoch+1,updated_at=? WHERE id=1",
          [.string(hash), .number(Date().timeIntervalSince1970)])
      }
    }
  }
  public func setting(_ key: String) throws -> String? {
    try access {
      try $0.rows("SELECT value FROM settings WHERE key=?", [.string(key)]).first?["value"]?.string
    }
  }
  public func set(_ key: String, _ value: String) throws {
    try access {
      try $0.run(
        "INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [.string(key), .string(value)])
    }
  }
  public func addDevice(id: String, label: String, hash: String, expires: Date) throws {
    try access { db in
      try db.run(
        "DELETE FROM device WHERE revoked_at IS NOT NULL OR expires_at<=?",
        [.number(Date().timeIntervalSince1970)])
      guard
        try db.rows(
          "SELECT id FROM device WHERE revoked_at IS NULL AND expires_at>?",
          [.number(Date().timeIntervalSince1970)], limit: 129
        ).count < 128
      else { throw APIError(429, "deviceLimit") }
      try db.run(
        "INSERT INTO device VALUES(?,?,?,?,?,NULL)",
        [
          .string(id), .string(label), .string(hash), .number(Date().timeIntervalSince1970),
          .number(expires.timeIntervalSince1970),
        ])
    }
  }
  public func validDevice(hash: String) throws -> String? {
    try access {
      try $0.rows(
        "SELECT id FROM device WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?",
        [.string(hash), .number(Date().timeIntervalSince1970)]
      ).first?["id"]?.string
    }
  }
  public func devices() throws -> JSONValue {
    try access {
      .array(
        try $0.rows(
          "SELECT id,label,created_at,expires_at,revoked_at FROM device ORDER BY created_at DESC LIMIT 128"
        ).map(JSONValue.object))
    }
  }
  public func revoke(id: String) throws {
    try access {
      try $0.run(
        "UPDATE device SET revoked_at=? WHERE id=?",
        [.number(Date().timeIntervalSince1970), .string(id)])
    }
  }
}
