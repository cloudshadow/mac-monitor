import Foundation
import MonitorCore

public struct OriginPolicy: Sendable {
  public let host: String, port: Int, tls: Bool
  public init(host: String, port: Int, tls: Bool) {
    self.host = host
    self.port = port
    self.tls = tls
  }
  public var authority: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
  public var origin: String { (tls ? "https://" : "http://") + authority }
  public func validate(
    method: String, host headers: [String], origin origins: [String], fetchSite: String?,
    protected: Bool
  ) throws {
    guard headers.count == 1, headers[0].lowercased() == authority.lowercased() else {
      throw APIError(403, "invalidHost")
    }
    guard method != "OPTIONS" else { throw APIError(403, "crossOriginDenied") }
    guard origins.count <= 1, origins.isEmpty || origins[0] == origin else {
      throw APIError(403, "crossOriginDenied")
    }
    let read = method == "GET" || method == "HEAD"
    if !read && origins.isEmpty { throw APIError(403, "originRequired") }
    if read && protected, let fetchSite, !["same-origin", "none"].contains(fetchSite) {
      throw APIError(403, "crossOriginDenied")
    }
  }
}
