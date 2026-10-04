import Foundation
import MonitorCore
import MonitorIPC
import MonitorServer
import Testing

struct ServiceControlTests {
  @Test func readsBootOverrideSeparatelyFromRunningState() throws {
    let state = try ServiceState.parse(config: .object(["bootEnabled": .bool(false)]),
      disabledOutput: "disabled services = {\n \"org.cloudmacmonitor.agent\" => disabled\n}",
      jobCode: 0, jobOutput: "state = running\npid = 123")
    #expect(state["bootEnabled"].bool == false)
    #expect(state["systemEnabled"].bool == false)
    #expect(state["running"].bool == true)
    let stopped = try ServiceState.parse(config: .object(["bootEnabled": .bool(true)]),
      disabledOutput: "disabled services = {\n}", jobCode: 113,
      jobOutput: "Could not find service \"org.cloudmacmonitor.agent\" in domain for system")
    #expect(stopped["bootEnabled"].bool == true)
    #expect(stopped["running"].bool == false)
  }
  @Test func unknownJobOrOverrideDoesNotPretendToBeStopped() {
    #expect(throws: APIError.self) {
      try ServiceState.parse(config: .object(["bootEnabled": .bool(true)]),
        disabledOutput: "disabled services = {\n}", jobCode: 1, jobOutput: "permission denied")
    }
    #expect(throws: APIError.self) { try ServiceState.isDisabled("permission denied") }
    #expect(throws: APIError.self) {
      try ServiceState.isDisabled("disabled services = {\n \"org.cloudmacmonitor.agent\" => unknown\n}")
    }
  }
  @Test func startsDisabledBootSessionAndRestoresPreference() throws {
    var calls: [[String]] = []
    try ServiceLifecycle.start(job: "fixture", plist: "fixture.plist", loaded: false, disabled: true) { calls.append($0) }
    #expect(calls == [["enable", "fixture"], ["bootstrap", "system", "fixture.plist"],
      ["kickstart", "fixture"], ["disable", "fixture"]])
  }
  @Test func failedStartStillRestoresDisabledBootPreference() {
    var calls: [[String]] = []
    #expect(throws: APIError.self) {
      try ServiceLifecycle.start(job: "fixture", plist: "fixture.plist", loaded: false, disabled: true) {
        calls.append($0)
        if $0.first == "bootstrap" { throw APIError(503, "launchctlFailed") }
      }
    }
    #expect(calls.last == ["disable", "fixture"])
  }
  @Test func stopFlushesAndBootsOutWithoutChangingBootOverride() throws {
    var calls: [String] = []
    try ServiceLifecycle.stop(job: "fixture", loaded: true, prepare: { calls.append("flush") }) {
      calls.append($0.joined(separator: " "))
    }
    #expect(calls == ["flush", "bootout fixture"])
    calls = []
    try ServiceLifecycle.stop(job: "fixture", loaded: false, prepare: { calls.append("unexpected") }) {
      calls.append($0.joined(separator: " "))
    }
    #expect(calls.isEmpty)
  }
  @Test func en0SelectionNeverFallsBackToAnotherInterface() {
    #expect(LanNetwork.defaultInterface(in: [.init(name: "en1", address: "192.168.1.2")]) == nil)
    let selected = LanNetwork.defaultInterface(in: [.init(name: "en1", address: "192.168.1.2"), .init(name: "en0", address: "192.168.1.3")])
    #expect(selected?.name == "en0")
  }
}
