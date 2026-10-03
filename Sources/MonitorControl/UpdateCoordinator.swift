import Foundation

struct AvailableUpdate: Sendable { let version: String, command: String }
enum UpdateCoordinator {
  static func check() async throws -> AvailableUpdate {
    guard let repository = Bundle.main.object(forInfoDictionaryKey: "ReleaseRepository") as? String,
      repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    else {
      throw NSError(domain: "Release source is not configured in this development build", code: 1)
    }
    let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 262144,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = value["tag_name"] as? String,
      tag.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    else { throw NSError(domain: "Invalid release metadata", code: 1) }
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    let version = String(tag.dropFirst())
    let base = "https://github.com/\(repository)/releases/download/\(tag)"
    let name = "CloudMacMonitor-\(version)-\(architecture).tar.gz.sha256"
    let (checksum, status) = try await URLSession.shared.data(from: URL(string: base + "/" + name)!)
    guard (status as? HTTPURLResponse)?.statusCode == 200, checksum.count < 1024,
      let digest = String(data: checksum, encoding: .utf8)?.split(separator: " ").first,
      digest.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
    else { throw NSError(domain: "Invalid release checksum", code: 1) }
    // Installer is saved for inspection, then executed without root. Its privileged phase is fixed.
    let installer = "https://raw.githubusercontent.com/\(repository)/\(tag)/scripts/install.sh"
    return AvailableUpdate(
      version: version,
      command:
        "task_installer=$(mktemp /private/tmp/cloudmacmonitor-install.XXXXXXXX) && curl --fail --proto '=https' '\(installer)' -o \"$task_installer\" && bash \"$task_installer\" '\(version)' '\(base)' '\(digest)'"
    )
  }
}
