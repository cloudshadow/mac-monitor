import Foundation
import MonitorCore

public enum LaunchctlCommand {
  public static func run(_ arguments: [String]) throws -> (Int32, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

public enum ServiceState {
  public static let label = "org.cloudmacmonitor.agent"
  public static let job = "system/" + label
  public static func isDisabled(_ output: String) throws -> Bool {
    guard output.contains("disabled services = {") else { throw APIError(503, "unknownServiceState") }
    for line in output.split(separator: "\n") {
      let pair = line.components(separatedBy: "=>")
      if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "\"\(label)\"" {
        let value = pair[1].trimmingCharacters(in: .whitespaces)
        guard ["true", "false", "enabled", "disabled"].contains(value) else {
          throw APIError(503, "unknownServiceState")
        }
        return value == "true" || value == "disabled"
      }
    }
    return false
  }
  public static func parse(config: JSONValue, disabledOutput: String, jobCode: Int32, jobOutput: String) throws -> JSONValue {
    guard let boot = config["bootEnabled"].bool else { throw APIError(503, "unknownServiceState") }
    let disabled = try isDisabled(disabledOutput)
    guard jobCode == 0 || jobOutput.contains("Could not find service \"\(label)\"") else {
      throw APIError(503, "unknownServiceState")
    }
    let loaded = jobCode == 0
    if loaded && !jobOutput.contains("state = ") { throw APIError(503, "unknownServiceState") }
    return .object([
      "bootEnabled": .bool(boot), "systemEnabled": .bool(!disabled),
      "loaded": .bool(loaded), "running": .bool(loaded && jobOutput.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" }),
    ])
  }
  public static func inspect(config: JSONValue) throws -> JSONValue {
    let (disabledCode, disabledOutput) = try LaunchctlCommand.run(["print-disabled", "system"])
    guard disabledCode == 0 else { throw APIError(503, "unknownServiceState") }
    let (jobCode, jobOutput) = try LaunchctlCommand.run(["print", job])
    return try parse(config: config, disabledOutput: disabledOutput, jobCode: jobCode, jobOutput: jobOutput)
  }
}

/// Starting and stopping this session preserve the system's boot override.
public enum ServiceLifecycle {
  public static func start(job: String, plist: String, loaded: Bool, disabled: Bool,
    run: ([String]) throws -> Void) throws {
    if disabled { try run(["enable", job]) }
    var failure: (any Error)?
    do {
      if !loaded { try run(["bootstrap", "system", plist]) }
      try run(["kickstart", job])
    } catch { failure = error }
    // Restore even when bootstrap/kickstart fails; surface restoration errors too.
    if disabled { try run(["disable", job]) }
    if let failure { throw failure }
  }
  public static func stop(job: String, loaded: Bool, prepare: () -> Void,
    run: ([String]) throws -> Void) throws {
    guard loaded else { return }
    prepare()
    try run(["bootout", job])
  }
}
