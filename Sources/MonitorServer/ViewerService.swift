import Foundation
import MonitorCore

private struct Viewer {
  let session: String
  var expires: Date, visible: Bool, channels: Set<String>, streaming = false
}
public final class ViewerService: @unchecked Sendable {
  private let viewers = Locked([String: Viewer]())
  public init() {}
  public func create(session: AccountSession, channels: [String]) throws -> JSONValue {
    try validate(channels)
    return try viewers.withLock { s in
      s = s.filter { $0.value.expires > Date() }
      guard s.count < 6 else { throw APIError(429, "viewerLimit") }
      let id = Crypto.random(16)
      let expiry = Date().addingTimeInterval(35)
      s[id] = Viewer(session: session.hash, expires: expiry, visible: true, channels: Set(channels))
      return .object(["viewerId": .string(id), "expiresAt": .date(expiry)])
    }
  }
  private func validate(_ channels: [String]) throws {
    guard !channels.isEmpty, channels.count <= 4,
      Set(channels).isSubset(of: ["system", "apps", "temperature", "gpu"])
    else { throw APIError(400, "invalidChannels") }
  }
  public func update(_ id: String, session: AccountSession, visible: Bool, channels: [String])
    throws -> JSONValue
  {
    try validate(channels)
    return try viewers.withLock { s in
      guard var v = s[id], v.session == session.hash, v.expires > Date() else {
        throw APIError(404, "viewerNotFound")
      }
      v.visible = visible
      v.channels = Set(channels)
      v.expires = Date().addingTimeInterval(35)
      s[id] = v
      return .object(["expiresAt": .date(v.expires)])
    }
  }
  public func delete(_ id: String, session: AccountSession) throws {
    try viewers.withLock { s in
      guard s[id]?.session == session.hash else { throw APIError(404, "viewerNotFound") }
      s.removeValue(forKey: id)
    }
  }
  public func open(_ id: String, session: AccountSession) throws {
    try viewers.withLock { s in
      guard var v = s[id], v.session == session.hash, v.expires > Date(), v.visible else {
        throw APIError(404, "viewerNotFound")
      }
      guard !v.streaming, s.values.filter({ $0.streaming && $0.expires > Date() }).count < 3 else {
        throw APIError(429, "streamLimit")
      }
      v.streaming = true
      s[id] = v
    }
  }
  public func close(_ id: String) { viewers.withLock { $0[id]?.streaming = false } }
  public func active(_ id: String, session: AccountSession) -> Set<String>? {
    viewers.withLock { s in
      guard let v = s[id], v.session == session.hash, v.expires > Date(), v.visible else {
        return nil
      }
      return v.channels
    }
  }
}
