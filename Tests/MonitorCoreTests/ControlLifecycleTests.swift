import Darwin
import AppKit
import Foundation
import MonitorCore
import MonitorIPC
@testable import MonitorControl
import Testing

@Suite(.serialized) @MainActor struct ControlLifecycleTests {
  private func fixture() throws -> (URL, String) {
    let root = URL(fileURLWithPath: "/private/tmp/cmm-ui-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("control.sock").path)
  }
  private func idle(_ model: ControlModel) async throws {
    let deadline = Date().addingTimeInterval(8)
    while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.busy)
  }
  @Test func automaticRefreshDoesNotDisableControlsOrClearActionErrors() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = JSONValue.object(["address": .string("http://127.0.0.1:8765")])
    let server = try LocalControlServer(path: path, ownerUid: getuid()) { _, _ in response }
    server.start()
    defer { server.stop() }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    model.error = "Previous action failed"
    model.refresh(silently: true)
    #expect(!model.busy)
    let deadline = Date().addingTimeInterval(8)
    while model.status == .null && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.status == response)
    #expect(!model.busy)
    #expect(model.error == "Previous action failed")
  }
  @Test func updateSelectionOnlyOffersStableReleasesAndComparesVersionsNumerically() {
    #expect(UpdateCoordinator.newestTag(in: [
      ["tag_name": "v0.1.9", "prerelease": false],
      ["tag_name": "v0.1.10", "prerelease": true],
      ["tag_name": "v9.0.0", "draft": true],
      ["tag_name": "v0.2.0;bad"],
    ]) == "v0.1.9")
    #expect(!UpdateCoordinator.isNewer("0.1.10", than: "0.1.10"))
    #expect(!UpdateCoordinator.isNewer("0.1.9", than: "0.1.10"))
    #expect(UpdateCoordinator.isNewer("0.1.10", than: "0.1.9"))
  }
  @Test func updateCheckAndInstallationHaveIndependentProgressAndRetryAfterFailure() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    let update = AvailableUpdate(version: "0.1.12", command: "fixture", releaseBase: "https://example.test/releases/v0.1.12", checksum: String(repeating: "a", count: 64))
    var checks = 0, installs = 0, reopens = 0
    model.fetchUpdate = {
      checks += 1
      try await Task.sleep(for: .milliseconds(50))
      return update
    }
    model.checkUpdates()
    model.checkUpdates()
    #expect(model.checkingUpdates && !model.busy)
    let deadline = Date().addingTimeInterval(8)
    while model.checkingUpdates && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.checkingUpdates && checks == 1 && model.update?.version == update.version)
    model.applyUpdate = { _ in
      installs += 1
      try await Task.sleep(for: .milliseconds(50))
      throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authorization canceled"])
    }
    model.reopenUpdatedApp = { reopens += 1 }
    model.installUpdate()
    model.installUpdate()
    #expect(model.installingUpdate && !model.checkingUpdates)
    while model.installingUpdate && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.installingUpdate && installs == 1 && reopens == 0 && !model.relaunching)
    #expect(model.updateStatus.contains("Authorization canceled"))
    model.applyUpdate = { _ in installs += 1 }
    model.installUpdate()
    while model.installingUpdate && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.installingUpdate && installs == 2 && reopens == 1 && model.relaunching)
    // Relaunching the control window must not shut down the updated service.
    #expect(ControlAppDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    model.relaunching = false
    model.fetchUpdate = { throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"]) }
    model.checkUpdates()
    while model.checkingUpdates && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.checkingUpdates && !model.busy && model.update == nil)
    #expect(model.updateStatus.contains("Network unavailable"))
  }
  @Test func appUpdateRunsBundledInstallerWithoutRootAndReportsFailure() async throws {
    let (root, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = root.appendingPathComponent("installer's script.sh")
    let checksum = String(repeating: "a", count: 64)
    let update = AvailableUpdate(version: "0.1.12", command: "unused", releaseBase: "https://example.test/releases/v0.1.12", checksum: checksum)
    try Data("""
      set -euo pipefail
      [[ "$(id -u)" != 0 && "$CMM_INSTALL_GUI" == 1 ]]
      [[ "$#" == 3 && "$1" == 0.1.12 && "$2" == https://example.test/releases/v0.1.12 && "$3" == \(checksum) ]]
      """.utf8).write(to: installer)
    try await UpdateCoordinator.install(update, installer: installer)
    try Data("echo 'Checksum mismatch; nothing installed.' >&2\nexit 1\n".utf8).write(to: installer)
    do {
      try await UpdateCoordinator.install(update, installer: installer)
      Issue.record("Failed installation was treated as successful")
    } catch {
      #expect(error.localizedDescription.contains("Checksum mismatch"))
    }
  }
  @Test func portInputRejectsInvalidValuesAndDisplaysConflictReason() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    for input in ["", "0", "65536", "1.5", "abc"] {
      model.configurePort(input)
      #expect(!model.busy)
      #expect(model.error == NativeKeys.invalidPort())
    }
    let server = try LocalControlServer(path: path, ownerUid: getuid()) { request, _ in
      #expect(request["command"].string == "setPort")
      #expect(request["port"].number == 9000)
      throw APIError(409, "localPortInUse")
    }
    server.start()
    defer { server.stop() }
    model.configurePort("9000")
    try await idle(model)
    #expect(model.error == NativeKeys.localPortInUse(port: "9000"))
  }
  @Test func statusFailureClearsStaleAddressAndShowsReason() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    model.status = .object(["address": .string("http://127.0.0.1:9999")])
    model.refresh()
    try await idle(model)
    #expect(model.status == .null)
    #expect(model.error.contains("controlUnavailable"))
  }
  @Test func openReadsServiceAgainInsteadOfUsingCachedAddress() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = Locked(0)
    let server = try LocalControlServer(path: path, ownerUid: getuid()) { request, _ in
      #expect(request["command"].string == "status")
      requests.withLock { $0 += 1 }
      return .object(["address": .string("invalid")])
    }
    server.start()
    defer { server.stop() }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    model.status = .object(["address": .string("http://127.0.0.1:9999")])
    model.openMonitor()
    try await idle(model)
    #expect(requests.withLock { $0 } == 1)
    #expect(model.status["address"].string == "invalid")
    #expect(model.error.contains("addressUnavailable"))
  }
  @Test func shutdownFailureReportsWarningButAllowsQuit() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    // Simulates a leftover socket path after an Agent crash.
    try Data().write(to: URL(fileURLWithPath: path))
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    var warning = ""
    model.reportShutdownFailure = { warning = $0 }
    let allowed = await withCheckedContinuation { continuation in
      model.quit { continuation.resume(returning: $0) }
    }
    #expect(allowed)
    #expect(warning.contains("controlUnavailable"))
  }
  @Test func absentServiceDoesNotPreventQuit() async throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    let allowed = await withCheckedContinuation { continuation in
      model.quit { continuation.resume(returning: $0) }
    }
    #expect(allowed)
    #expect(model.error.isEmpty)
  }
  @Test func mergedControlsUseIndependentStatesAndWaitForObservation() throws {
    let (root, path) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ControlModel(socketPath: path, ownerUid: getuid())
    #expect(model.bootEnabled == nil && model.running == nil)
    model.toggleBoot(); model.toggleService()
    #expect(!model.busy)
    model.serviceStatus = .object(["bootEnabled": .bool(false), "systemEnabled": .bool(false), "running": .bool(true)])
    #expect(model.bootEnabled == false && model.running == true)
    model.serviceStatus = .object(["bootEnabled": .bool(true), "systemEnabled": .bool(false), "running": .bool(false)])
    #expect(model.bootEnabled == false && model.running == false)
  }
}
