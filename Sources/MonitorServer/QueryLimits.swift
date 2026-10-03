import Foundation
import MonitorCore

public final class QueryLimits: @unchecked Sendable {
  private struct State {
    var global: [Date] = []
    var sessions: [String: [Date]] = [:]
  }
  private let state = Locked(State())
  public init() {}
  public func accept(session: String) throws {
    try state.withLock { value in
      let now = Date()
      let cutoff = now.addingTimeInterval(-1)
      value.global.removeAll { $0 < cutoff }
      value.sessions = value.sessions.filter { $0.value.last.map { $0 >= cutoff } ?? false }
      var local = (value.sessions[session] ?? []).filter { $0 >= cutoff }
      guard value.global.count < 60, local.count < 12,
        value.sessions.count < 128 || value.sessions[session] != nil
      else { throw APIError(429, "queryRateLimited", ["retryAfterMs": .number(1000)]) }
      local.append(now)
      value.global.append(now)
      value.sessions[session] = local
    }
  }
}
