import Darwin
import Foundation
import MonitorCore
import MonitorServer
import Testing

@Suite(.serialized) struct PortConfigurationTests {
  private func fixture() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp/cmm-port-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
  private func occupy(_ host: String = "127.0.0.1") throws -> (Int32, Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw APIError(503, "testSocketFailed") }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var success = false
    defer { if !success { close(fd) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw APIError(400, "testAddressFailed") }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 1) == 0 else { throw APIError(503, "testBindFailed") }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let inspected = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard inspected == 0 else { throw APIError(503, "testAddressFailed") }
    success = true
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
  }
  @Test func portChangePersistsAndConflictsPreserveCurrentListeners() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try AgentRuntime(root: root.path, webRoot: root.path)
    try runtime.start(port: 0)
    var stopped = false
    do {
      let before = try await runtime.command(.object(["command": .string("status")]))
      let (occupied, blockedPort) = try occupy()
      defer { close(occupied) }
      do {
        _ = try await runtime.command(.object(["command": .string("setPort"), "port": .number(Double(blockedPort))]))
        Issue.record("An occupied local port must be rejected")
      } catch { #expect((error as? APIError)?.code == "localPortInUse") }
      let rejected = try await runtime.command(.object(["command": .string("status")]))
      #expect(rejected["address"] == before["address"])
      #expect(try runtime.state.setting("listenPort") == nil)
      for invalid in [0.0, -1.0, 65536.0, 12.5] {
        do {
          _ = try await runtime.command(.object(["command": .string("setPort"), "port": .number(invalid)]))
          Issue.record("An invalid port must be rejected")
        } catch { #expect((error as? APIError)?.code == "invalidPort") }
      }
      // Obtain an available port and release it immediately before applying the change.
      let (reservation, port) = try occupy()
      close(reservation)
      let result = try await runtime.command(.object(["command": .string("setPort"), "port": .number(Double(port))]))
      #expect(result["actualPort"].number == Double(port))
      #expect(result["configuredPort"].number == Double(port))
      #expect(result["portFallback"].bool == false)
      #expect(try runtime.state.setting("listenPort") == String(port))
      if let lan = result["lanAddress"].string, !lan.isEmpty {
        #expect(URLComponents(string: lan)?.port == port)
      }
      let (body, response) = try await URLSession.shared.data(from: URL(string: runtime.address + "/healthz")!)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(!body.isEmpty)
      await runtime.shutdown()
      stopped = true
      let restarted = try AgentRuntime(root: root.path, webRoot: root.path)
      try restarted.start()
      #expect(URLComponents(string: restarted.address)?.port == port)
      await restarted.shutdown()
    } catch {
      if !stopped { await runtime.shutdown() }
      throw error
    }
  }
  @Test func startupFallbackIsReportedAndLANConflictIsExplicit() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let (occupied, blockedPort) = try occupy()
    defer { close(occupied) }
    let runtime = try AgentRuntime(root: root.path, webRoot: root.path)
    try runtime.state.set("listenPort", String(blockedPort))
    try runtime.start()
    do {
      let status = try await runtime.command(.object(["command": .string("status")]))
      #expect(status["configuredPort"].number == Double(blockedPort))
      #expect(status["portFallback"].bool == true)
      #expect(status["actualPort"].number != Double(blockedPort))
      if let chosen = LanNetwork.defaultInterface(in: LanNetwork.interfaces()) {
        let (lanSocket, lanPort) = try occupy(chosen.address)
        defer { close(lanSocket) }
        do {
          _ = try await runtime.command(.object(["command": .string("setPort"), "port": .number(Double(lanPort))]))
          Issue.record("An occupied LAN port must be rejected")
        } catch { #expect((error as? APIError)?.code == "lanPortInUse") }
        let rejected = try await runtime.command(.object(["command": .string("status")]))
        #expect(rejected["address"] == status["address"])
        #expect(try runtime.state.setting("listenPort") == String(blockedPort))
      }
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }
}
