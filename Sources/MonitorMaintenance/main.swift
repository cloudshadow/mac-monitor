import Darwin
import Foundation
import MonitorCore
import MonitorIPC

let root = InstallationLayout.root
let app = InstallationLayout.app
let label = "org.cloudmacmonitor.agent"
let plist = "/Library/LaunchDaemons/org.cloudmacmonitor.agent.plist"
let job = "system/org.cloudmacmonitor.agent"
func protected(_ path: String) throws {
  var url = URL(fileURLWithPath: path)
  while url.path != "/" {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
      info.st_mode & S_IFMT != S_IFLNK
    else { throw APIError(503, "unsafeInstallation") }
    url.deleteLastPathComponent()
  }
}
@discardableResult func run(_ arguments: [String], allowFailure: Bool = false) throws -> (
  Int32, String
) {
  let task = Process()
  let pipe = Pipe()
  task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
  task.arguments = arguments
  task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
  task.standardOutput = pipe
  task.standardError = pipe
  try task.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  task.waitUntilExit()
  guard allowFailure || task.terminationStatus == 0 else { throw APIError(503, "launchctlFailed") }
  return (task.terminationStatus, String(decoding: data, as: UTF8.self))
}
func disabled() throws -> Bool {
  try ServiceState.isDisabled(run(["print-disabled", "system"]).1)
}
func observed(_ config: JSONValue) throws -> JSONValue {
  try ServiceState.inspect(config: config)
}
func save(_ value: JSONValue, _ filename: String) throws {
  try value.data().write(to: URL(fileURLWithPath: root + "/" + filename), options: .atomic)
  chmod(root + "/" + filename, filename == "installation.json" ? 0o644 : 0o600)
}
var actual: JSONValue = .null
do {
  guard geteuid() == 0, CommandLine.arguments.count == 2,
    ["status", "enable", "start", "disable", "stop", "uninstall", "uninstallData", "installLink"].contains(
      CommandLine.arguments[1])
  else { throw APIError(403, "administratorRequired") }
  try protected(app + "/Contents/MacOS/MonitorMaintenance")
  try protected(root + "/installation.json")
  let lock = open(root + "/maintenance.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
  guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
    throw APIError(409, "maintenanceBusy")
  }
  defer { close(lock) }
  let path = root + "/installation.json"
  var config = try JSONDecoder().decode(
    JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  guard let uidValue = config["ownerUid"].number, uidValue > 0,
    let ownerName = config["ownerName"].string, let record = getpwnam(ownerName),
    record.pointee.pw_uid == uid_t(uidValue)
  else { throw APIError(503, "ownerIdentityMismatch") }
  try OwnerIdentity.verify(
    name: ownerName, uid: uid_t(uidValue), generatedUID: config["ownerGuid"].string ?? "")
  let uid = uid_t(uidValue)
  let action = CommandLine.arguments[1]
  actual = try observed(config)
  if action != "status" {
    try save(
      .object(["operation": .string(action), "phase": .string("started"), "before": actual]),
      "operation.json")
  }
  func bootChoice(_ enabled: Bool) throws {
    if case .object(var value) = config {
      value["bootEnabled"] = .bool(enabled)
      config = .object(value)
    }
    try save(config, "installation.json")
  }
  func stopSession() throws {
    try ServiceLifecycle.stop(job: job, loaded: actual["loaded"].bool == true, prepare: {
      let ready = try? LocalControl.request(
        path: root + "/data/run/control.sock", ownerUid: uid,
        body: .object(["command": .string("prepareStop")]))
      if ready?["ready"].bool != true {
        FileHandle.standardError.write(Data("Agent flush was not confirmed; the last uncommitted window may be lost.\n".utf8))
      }
    }, run: { _ = try run($0) })
  }
  switch action {
  case "installLink":
    var directory = stat()
    guard lstat("/Applications", &directory) == 0,
      InstallationPathPolicy.applicationsDirectory(uid: directory.st_uid, gid: directory.st_gid, mode: directory.st_mode)
    else { throw APIError(503, "unsafeApplicationsDirectory") }
    try ApplicationLauncherLink.install(
      bundle: app, launcher: InstallationLayout.launcher, staging: root + "/.applications-link.new")
  case "disable":
    try run(["disable", job])
    guard try disabled() else { throw APIError(503, "disableFailed") }
    try bootChoice(false)
  case "stop":
    try stopSession()
  case "uninstall", "uninstallData":
    try run(["disable", job])
    guard try disabled() else { throw APIError(503, "disableFailed") }
    try bootChoice(false)
    try stopSession()
    try protected(plist)
    try FileManager.default.removeItem(atPath: plist)
    try ApplicationLauncherLink.remove(bundle: app, launcher: InstallationLayout.launcher)
    try FileManager.default.removeItem(atPath: app)
  case "enable":
    try protected(plist)
    try run(["enable", job])
    try bootChoice(true)
  case "start":
    try protected(plist)
    let circuit = root + "/data/startup-attempts.json"
    var info = stat()
    if lstat(circuit, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid, info.st_nlink == 1 else {
        throw APIError(503, "unsafeDataPath")
      }
      guard unlink(circuit) == 0 else { throw APIError(503, "startupCircuitResetFailed") }
    }
    try ServiceLifecycle.start(job: job, plist: plist, loaded: actual["loaded"].bool == true,
      disabled: try disabled(), run: { _ = try run($0) })
  default: break
  }
  actual = try observed(config)
  if action != "status" {
    try save(
      .object(["operation": .string(action), "phase": .string("completed"), "actual": actual]),
      "operation.json")
  }
  if action == "uninstallData" { try FileManager.default.removeItem(atPath: root) }
  FileHandle.standardOutput.write(try actual.data())
  FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
  // Report the observed state after a partial operation rather than the old snapshot.
  if getuid() == 0,
    let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/installation.json")),
    let config = try? JSONDecoder().decode(JSONValue.self, from: data),
    let current = try? observed(config) { actual = current }
  let error = error as? APIError ?? APIError(503, "maintenanceFailed")
  FileHandle.standardOutput.write(
    (try? JSONValue.object(["error": error.json["error"], "actual": actual]).data()) ?? Data())
  exit(1)
}
