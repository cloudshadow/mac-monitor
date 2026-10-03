import Darwin
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
}
