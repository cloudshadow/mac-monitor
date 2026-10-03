import Darwin
import Foundation
import MonitorCore

public enum StartupGuard {
  public static func record(root: String) throws {
    let path = root + "/startup-attempts.json"
    var info = stat()
    var attempts: [Double] = []
    if lstat(path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
        info.st_size <= 1024
      else { throw APIError(503, "unsafeDataPath") }
      attempts = try JSONDecoder().decode(
        [Double].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    let now = Date().timeIntervalSince1970
    attempts = attempts.filter { now - $0 < 300 && now >= $0 }
    guard attempts.count < 3 else { throw APIError(503, "startupCircuitOpen") }
    attempts.append(now)
    try JSONEncoder().encode(attempts).write(to: URL(fileURLWithPath: path), options: .atomic)
    chmod(path, 0o600)
  }
  public static func stable(root: String) {
    try? Data("[]".utf8).write(
      to: URL(fileURLWithPath: root + "/startup-attempts.json"), options: .atomic)
    chmod(root + "/startup-attempts.json", 0o600)
  }
}
