import Clibsodium
import Foundation
import HistoryStore
import MonitorCore

public enum Crypto {
  public static func random(_ count: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    randombytes_buf(&bytes, bytes.count)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
  public static func hash(_ text: String) -> String {
    let bytes = Array(text.utf8)
    var output = [UInt8](repeating: 0, count: 32)
    bytes.withUnsafeBufferPointer {
      _ = crypto_generichash(&output, output.count, $0.baseAddress, UInt64($0.count), nil, 0)
    }
    return output.map { String(format: "%02x", $0) }.joined()
  }
  public static func equal(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return x.withUnsafeBytes { xp in
      y.withUnsafeBytes { yp in sodium_memcmp(xp.baseAddress, yp.baseAddress, x.count) == 0 }
    }
  }
}

public struct AccountSession: Sendable {
  public let hash: String, epoch: Int64, lan: Bool, expiresAt: Date
}
public struct AuthResult: Sendable {
  public let token: String, csrf: String, expiresAt: Date
}
private struct AuthMemory {
  var sessions: [String: AccountSession] = [:]
  var setup: [String: Date] = [:]
  var attempts: [String: [Date]] = [:], global: [Date] = []
  var kdfPending = 0
}

public final class AuthService: @unchecked Sendable {
  public let store: StateStore
  private let state = Locked(AuthMemory())
  private let kdfQueue = DispatchQueue(label: "org.cloudmacmonitor.password", qos: .userInitiated)
  private let csrfKey: [UInt8]
  public var onRevocation: (@Sendable () -> Void)?
  public init(store: StateStore) throws {
    guard sodium_init() >= 0 else { throw APIError(503, "cryptoUnavailable") }
    self.store = store
    var bytes = [UInt8](repeating: 0, count: 32)
    randombytes_buf(&bytes, bytes.count)
    csrfKey = bytes
  }
  public static func validate(username: String, password: String) throws -> String {
    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping.lowercased()
    guard (1...64).contains(user.count), user.utf8.count <= 256,
      !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      (12...128).contains(password.count), password.utf8.count <= 512
    else { throw APIError(400, "invalidCredentialsFormat") }
    return user
  }
  private func limit(_ ip: String) throws {
    try state.withLock { s in
      let now = Date()
      let cutoff = now.addingTimeInterval(-60)
      s.global.removeAll { $0 < cutoff }
      s.attempts = s.attempts.filter { $0.value.last.map { $0 >= cutoff } ?? false }
      var local = (s.attempts[ip] ?? []).filter { $0 >= cutoff }
      guard s.global.count < 10, local.count < 5, s.attempts.count < 1_024 || s.attempts[ip] != nil
      else { throw APIError(429, "rateLimited", ["retryAfterMs": .number(60_000)]) }
      local.append(now)
      s.global.append(now)
      s.attempts[ip] = local
    }
  }
  private func kdf<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try state.withLock { s in
      guard s.kdfPending < 3 else {
        throw APIError(429, "authQueueFull", ["retryAfterMs": .number(1_000)])
      }
      s.kdfPending += 1
    }
    return try await withCheckedThrowingContinuation { continuation in
      kdfQueue.async { [self] in
        defer { state.withLock { $0.kdfPending -= 1 } }
        do { continuation.resume(returning: try operation()) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  private static func passwordHash(_ password: String) throws -> String {
    let bytes = Array(password.utf8) + [0]
    var out = [CChar](repeating: 0, count: Int(crypto_pwhash_strbytes()))
    let result = bytes.withUnsafeBytes { b in
      crypto_pwhash_str_alg(
        &out, b.baseAddress!.assumingMemoryBound(to: CChar.self), UInt64(bytes.count - 1),
        UInt64(crypto_pwhash_opslimit_interactive()), 64 * 1_024 * 1_024,
        crypto_pwhash_alg_argon2id13())
    }
    guard result == 0 else { throw APIError(503, "authUnavailable") }
    return out.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }
  public func issueSetupTicket() throws -> String {
    guard try store.account() == nil else { throw APIError(409, "accountExists") }
    let ticket = Crypto.random()
    state.withLock { $0.setup = [Crypto.hash(ticket): Date().addingTimeInterval(300)] }
    return ticket
  }
  public func setup(ticket: String, username: String, password: String, ip: String, localFirstRun: Bool = false) async throws
    -> AuthResult
  {
    try limit(ip)
    let user = try Self.validate(username: username, password: password)
    guard !store.recoveryRequired else { throw APIError(409, "recoveryRequired") }
    guard try store.account() == nil else { throw APIError(409, "accountExists") }
    // The HTTP route grants localFirstRun only on the loopback listener after Origin validation.
    // StateStore.create performs the final atomic single-account check after the asynchronous KDF.
    if !localFirstRun {
      try state.withLock { s in
        guard let date = s.setup.removeValue(forKey: Crypto.hash(ticket)), date > Date() else {
          throw APIError(403, "setupTicketInvalid")
        }
      }
    }
    let hash = try await kdf { try Self.passwordHash(password) }
    try store.create(username: user, hash: hash)
    return try createSession(lan: false)
  }
  public func login(username: String, password: String, ip: String, lan: Bool)
    async throws -> AuthResult
  {
    try limit(ip)
    // Validate lengths without revealing whether the username exists.
    guard username.count <= 64, password.count <= 128, password.utf8.count <= 512 else {
      throw APIError(401, "invalidCredentials")
    }
    guard let account = try store.account() else { throw APIError(401, "invalidCredentials") }
    let matches = try await kdf {
      let bytes = Array(password.utf8) + [0]
      return bytes.withUnsafeBytes { b in
        crypto_pwhash_str_verify(
          account.passwordHash, b.baseAddress!.assumingMemoryBound(to: CChar.self),
          UInt64(bytes.count - 1)) == 0
      }
    }
    guard matches,
      username.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        .lowercased() == account.username
    else { throw APIError(401, "invalidCredentials") }
    guard try store.account()?.epoch == account.epoch else { throw APIError(401, "loginRequired") }
    return try createSession(lan: lan, expectedEpoch: account.epoch)
  }
  private func createSession(lan: Bool, expectedEpoch: Int64? = nil) throws -> AuthResult {
    guard let account = try store.account() else { throw APIError(401, "loginRequired") }
    guard expectedEpoch == nil || expectedEpoch == account.epoch else {
      throw APIError(401, "loginRequired")
    }
    let token = Crypto.random()
    let hash = Crypto.hash(token)
    let expiry = Date().addingTimeInterval(43_200)
    let session = AccountSession(
      hash: hash, epoch: account.epoch, lan: lan, expiresAt: expiry)
    try state.withLock { s in
      s.sessions = s.sessions.filter { $0.value.expiresAt > Date() }
      guard s.sessions.count < 128 else { throw APIError(429, "sessionLimit") }
      s.sessions[hash] = session
    }
    return AuthResult(token: token, csrf: try csrf(for: session), expiresAt: expiry)
  }
  public func session(token: String?, lan: Bool) throws -> AccountSession {
    guard let token, let session = state.withLock({ $0.sessions[Crypto.hash(token)] }),
      session.expiresAt > Date(), session.lan == lan,
      session.epoch == (try store.account()?.epoch)
    else { throw APIError(401, "loginRequired") }
    return session
  }
  public func csrf(for session: AccountSession) throws -> String {
    let message = Array(session.hash.utf8)
    var out = [UInt8](repeating: 0, count: 32)
    csrfKey.withUnsafeBufferPointer { key in
      message.withUnsafeBufferPointer { msg in
        _ = crypto_auth_hmacsha256(&out, msg.baseAddress, UInt64(msg.count), key.baseAddress!)
      }
    }
    return out.map { String(format: "%02x", $0) }.joined()
  }
  public func validateCSRF(_ token: String?, session: AccountSession) throws {
    guard let token, Crypto.equal(token, try csrf(for: session)) else {
      throw APIError(403, "csrfRequired")
    }
  }
  public func logout(token: String?) {
    if let token {
      _ = state.withLock { $0.sessions.removeValue(forKey: Crypto.hash(token)) }
      onRevocation?()
    }
  }
  public func resetPassword(_ password: String) async throws {
    guard let account = try store.account() else { throw APIError(409, "setupRequired") }
    _ = try Self.validate(username: account.username, password: password)
    let hash = try await kdf { try Self.passwordHash(password) }
    try store.changePassword(hash: hash)
    state.withLock {
      $0.sessions.removeAll()
      $0.setup.removeAll()
    }
    onRevocation?()
  }
  public func changePassword(old: String, new: String) async throws {
    guard let account = try store.account() else { throw APIError(409, "setupRequired") }
    let valid = try await kdf {
      let bytes = Array(old.utf8) + [0]
      return bytes.withUnsafeBytes {
        crypto_pwhash_str_verify(
          account.passwordHash, $0.baseAddress!.assumingMemoryBound(to: CChar.self),
          UInt64(bytes.count - 1)) == 0
      }
    }
    guard valid else { throw APIError(401, "invalidCredentials") }
    try await resetPassword(new)
  }
  public func recoverState() throws -> String {
    try store.recover()
    state.withLock {
      $0.sessions.removeAll()
      $0.setup.removeAll()
    }
    onRevocation?()
    return try issueSetupTicket()
  }
}
