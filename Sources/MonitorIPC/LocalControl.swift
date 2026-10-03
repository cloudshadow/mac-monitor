import Darwin
import Foundation
import MonitorCore

private func address(_ path: String) throws -> sockaddr_un {
  var a = sockaddr_un()
  a.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else {
    throw APIError(400, "socketPathTooLong")
  }
  withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }
  a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return a
}
private func timeout(_ fd: Int32) {
  var t = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
  var yes: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
}
private func writeAll(_ fd: Int32, _ data: Data) throws {
  try data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
      guard count > 0 else { throw APIError(503, "controlUnavailable") }
      offset += count
    }
  }
}
private func readLine(_ fd: Int32) throws -> Data {
  var data = Data()
  var byte: UInt8 = 0
  while data.count <= 16_384 {
    let count = recv(fd, &byte, 1, 0)
    guard count == 1 else { throw APIError(503, "controlUnavailable") }
    if byte == 10 { return data }
    data.append(byte)
  }
  throw APIError(400, "requestTooLarge")
}

public enum LocalControl {
  public static func request(path: String, ownerUid: uid_t, body: JSONValue) throws -> JSONValue {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw APIError(503, "controlUnavailable") }
    defer { close(fd) }
    timeout(fd)
    var a = try address(path)
    let result = withUnsafePointer(to: &a) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw APIError(503, "controlUnavailable") }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == ownerUid else {
      throw APIError(403, "serviceIdentityMismatch")
    }
    var data = try body.data()
    data.append(10)
    try writeAll(fd, data)
    let value = try JSONDecoder().decode(JSONValue.self, from: readLine(fd))
    if let code = value["error"]["code"].string {
      throw APIError(Int(value["error"]["status"].number ?? 503), code)
    }
    return value
  }
}

public final class LocalControlServer: @unchecked Sendable {
  private let fd: Int32, path: String, ownerUid: uid_t
  private let handler: @Sendable (JSONValue, uid_t) async throws -> JSONValue
  private let stopped = Locked(false)
  public init(
    path: String, ownerUid: uid_t,
    handler: @escaping @Sendable (JSONValue, uid_t) async throws -> JSONValue
  ) throws {
    self.path = path
    self.ownerUid = ownerUid
    self.handler = handler
    var info = stat()
    if lstat(path, &info) == 0 {
      guard info.st_uid == ownerUid, info.st_mode & S_IFMT == S_IFSOCK else {
        throw APIError(503, "unsafeDataPath")
      }
      unlink(path)
    }
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw APIError(503, "controlUnavailable") }
    var a = try address(path)
    let result = withUnsafePointer(to: &a) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
      close(fd)
      throw APIError(503, "controlUnavailable")
    }
  }
  public func start() {
    Thread.detachNewThread { [self] in
      while !stopped.withLock({ $0 }) {
        let client = accept(fd, nil, nil)
        if client < 0 { break }
        timeout(client)
        var uid: uid_t = 0
        var gid: gid_t = 0
        do {
          guard getpeereid(client, &uid, &gid) == 0, uid == ownerUid || uid == 0 else {
            throw APIError(403, "ownerRequired")
          }
          let request = try JSONDecoder().decode(JSONValue.self, from: readLine(client))
          if uid == 0 && uid != ownerUid && request["command"].string != "prepareStop" {
            throw APIError(403, "ownerRequired")
          }
          let semaphore = DispatchSemaphore(value: 0)
          let result = Locked<Result<JSONValue, any Error>?>(nil)
          let peer = uid
          Task {
            do {
              let response = try await handler(request, peer)
              result.withLock { $0 = .success(response) }
            } catch { result.withLock { $0 = .failure(error) } }
            semaphore.signal()
          }
          guard semaphore.wait(timeout: .now() + 5) == .success,
            let response = result.withLock({ $0 })
          else { throw APIError(503, "controlTimeout") }
          var data = try response.get().data()
          data.append(10)
          try writeAll(client, data)
        } catch {
          let e = (error as? APIError) ?? APIError(503, "controlUnavailable")
          var d = e.details
          d["code"] = .string(e.code)
          d["status"] = .number(Double(e.status))
          if var data = try? JSONValue.object(["error": .object(d)]).data() {
            data.append(10)
            try? writeAll(client, data)
          }
        }
        close(client)
      }
    }
  }
  public func stop() {
    stopped.withLock { $0 = true }
    shutdown(fd, SHUT_RDWR)
    close(fd)
    unlink(path)
  }
}
