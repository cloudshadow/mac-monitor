import Foundation

struct AvailableUpdate: Sendable { let version: String, command: String, releaseBase: String, checksum: String }
enum UpdateCoordinator {
  static func isNewer(_ version: String, than current: String) -> Bool {
    version.compare(current, options: .numeric) == .orderedDescending
  }
  static func newestTag(in releases: [[String: Any]]) -> String? {
    let tags = releases.filter { $0["draft"] as? Bool != true && $0["prerelease"] as? Bool != true }.compactMap { $0["tag_name"] as? String }
      .filter { $0.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil }
    return tags.max(by: { isNewer(String($1.dropFirst()), than: String($0.dropFirst())) })
  }
  static func check() async throws -> AvailableUpdate? {
    guard let repository = Bundle.main.object(forInfoDictionaryKey: "ReleaseRepository") as? String,
      repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    else {
      throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "ReleaseRepository is not configured"])
    }
    let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("MacMonitor", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_097_152,
      let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid release response (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"]) }
    // Automatic updates only offer published stable releases.
    guard let tag = newestTag(in: releases)
    else { throw NSError(domain: "Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "No published release is available"]) }
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    guard isNewer(String(tag.dropFirst()), than: current) else { return nil }
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    let version = String(tag.dropFirst())
    let base = "https://github.com/\(repository)/releases/download/\(tag)"
    let name = "MacMonitor-\(version)-\(architecture).tar.gz.sha256"
    var checksumRequest = URLRequest(url: URL(string: base + "/" + name)!)
    checksumRequest.timeoutInterval = 10
    let (checksum, status) = try await URLSession.shared.data(for: checksumRequest)
    guard (status as? HTTPURLResponse)?.statusCode == 200, checksum.count < 1024,
      let digest = String(data: checksum, encoding: .utf8)?.split(whereSeparator: { $0.isWhitespace }).first,
      digest.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
    else { throw NSError(domain: "Update", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid release checksum (HTTP \((status as? HTTPURLResponse)?.statusCode ?? 0))"]) }
    // Installer is saved for inspection, then executed without root. Its privileged phase is fixed.
    let installer = "https://raw.githubusercontent.com/\(repository)/\(tag)/scripts/install.sh"
    return AvailableUpdate(
      version: version,
      command:
        "task_installer=$(mktemp /private/tmp/cloudmacmonitor-install.XXXXXXXX) && curl --fail --proto '=https' '\(installer)' -o \"$task_installer\" && bash \"$task_installer\" '\(version)' '\(base)' '\(digest)'",
      releaseBase: base, checksum: String(digest)
    )
  }
  static func install(_ update: AvailableUpdate, installer: URL? = Bundle.main.url(forResource: "install", withExtension: "sh")) async throws {
    guard let installer else {
      throw NSError(domain: "Update", code: 4, userInfo: [NSLocalizedDescriptionKey: "The bundled installer is missing"])
    }
    try await Task.detached {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmm-update-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let log = root.appendingPathComponent("install.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let output = try FileHandle(forWritingTo: log)
      defer { try? output.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [installer.path, update.version, update.releaseBase, update.checksum]
      process.environment = ProcessInfo.processInfo.environment.merging(["CMM_INSTALL_GUI": "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        throw NSError(domain: "Update", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(detail.suffix(4096))])
      }
    }.value
  }
}
