import Foundation
import HistoryStore
import MonitorCore
import MonitorServer
import Testing

struct AuthTests {
  func directory() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }
  @Test func corruptedStateNeverAllowsSetup() throws {
    let d = try directory()
    defer { try? FileManager.default.removeItem(at: d) }
    let p = d.appendingPathComponent("state.sqlite")
    try Data("corrupted".utf8).write(to: p)
    let state = StateStore(path: p.path)
    #expect(state.recoveryRequired)
    #expect(throws: APIError.self) { try state.create(username: "owner", hash: "fixture") }
    #expect(try Data(contentsOf: p) == Data("corrupted".utf8))
  }
  @Test func setupIsUniqueAndPasswordChangeRevokesAllSessions() async throws {
    let d = try directory()
    defer { try? FileManager.default.removeItem(at: d) }
    let store = StateStore(path: d.appendingPathComponent("state.sqlite").path)
    let auth = try AuthService(store: store)
    let ticket = try auth.issueSetupTicket()
    let result = try await auth.setup(
      ticket: ticket, username: "Owner", password: "a valid password 123", ip: "local")
    #expect(try auth.session(token: result.token, deviceToken: nil, lan: false).epoch == 1)
    #expect(throws: APIError.self) { try store.create(username: "second", hash: "fixture") }
    try await auth.resetPassword("a changed password 456")
    #expect(throws: APIError.self) {
      try auth.session(token: result.token, deviceToken: nil, lan: false)
    }
    let login = try await auth.login(
      username: "OWNER", password: "a changed password 456", ip: "local", deviceToken: nil,
      lan: false)
    let csrf1 = try auth.csrf(for: auth.session(token: login.token, deviceToken: nil, lan: false))
    #expect(csrf1 == login.csrf)
    auth.logout(token: login.token)
    #expect(throws: APIError.self) {
      try auth.session(token: login.token, deviceToken: nil, lan: false)
    }
    #expect(try StateStore(path: store.path).account()?.epoch == 2)
  }
  @Test func originMatrixMatchesContract() throws {
    let policy = OriginPolicy(host: "127.0.0.1", port: 8765, tls: false)
    try policy.validate(
      method: "GET", host: ["127.0.0.1:8765"], origin: [], fetchSite: "same-origin", protected: true
    )
    for origin in [
      [], ["null"], ["http://localhost:8765"], ["http://127.0.0.1:8765", "http://127.0.0.1:8765"],
    ] {
      #expect(throws: APIError.self) {
        try policy.validate(
          method: "POST", host: ["127.0.0.1:8765"], origin: origin, fetchSite: nil, protected: false
        )
      }
    }
    #expect(throws: APIError.self) {
      try policy.validate(
        method: "GET", host: ["evil.example:8765"], origin: [], fetchSite: nil, protected: true)
    }
    #expect(throws: APIError.self) {
      try policy.validate(
        method: "GET", host: ["127.0.0.1:8765"], origin: [], fetchSite: "cross-site",
        protected: true)
    }
  }
}

@Test func explicitRecoveryPreservesDamagedDatabaseAndHistory() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let path = root.appendingPathComponent("state.sqlite").path
  let damaged = Data("damaged-state-file".utf8)
  try damaged.write(to: URL(fileURLWithPath: path))
  let store = StateStore(path: path)
  let auth = try AuthService(store: store)
  #expect(store.recoveryRequired)
  let ticket = try auth.recoverState()
  #expect(try Data(contentsOf: URL(fileURLWithPath: path + ".recovery")) == damaged)
  #expect(!store.recoveryRequired)
  _ = try await auth.setup(
    ticket: ticket, username: "recovered", password: "recovered-password-12345", ip: "recovery")
  #expect(try store.account()?.username == "recovered")
}

@Test func concurrentAccountCreationHasExactlyOneWinner() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = StateStore(path: root.appendingPathComponent("state.sqlite").path)
  let successes = await withTaskGroup(of: Bool.self) { group in
    for index in 0..<8 {
      group.addTask {
        do {
          try store.create(username: "owner-\(index)", hash: "test-hash")
          return true
        } catch { return false }
      }
    }
    var total = 0
    for await success in group { if success { total += 1 } }
    return total
  }
  #expect(successes == 1)
  #expect(try store.account() != nil)
}
