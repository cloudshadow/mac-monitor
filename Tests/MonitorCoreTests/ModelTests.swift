import Foundation
import MacCollectors
import MaintenancePrototype
import MonitorCore
import ProbeSupport
import Testing

struct ModelTests {
  @Test func testCPUFirstSampleAndCounterRollbackAreUnavailable() {
    var baseline = CPUBaseline()
    #expect(baseline.percent(.init(user: 10, system: 10, idle: 80, nice: 0)) == nil)
    #expect(baseline.percent(.init(user: 30, system: 20, idle: 150, nice: 0)) == 30)
    #expect(baseline.percent(.init(user: 1, system: 1, idle: 1, nice: 0)) == nil)
    baseline.reset()
    #expect(baseline.percent(.init(user: 5, system: 5, idle: 5, nice: 0)) == nil)
  }
  @Test func testPIDReuseAndWakeResetNeverProduceRate() {
    var baseline = CounterBaseline()
    #expect(baseline.rate(identity: "pid:old", counter: 100, monotonicNs: 1_000_000_000) == nil)
    #expect(baseline.rate(identity: "pid:old", counter: 200, monotonicNs: 2_000_000_000) == 100)
    #expect(baseline.rate(identity: "pid:new", counter: 500, monotonicNs: 3_000_000_000) == nil)
    #expect(baseline.rate(identity: "pid:new", counter: 1, monotonicNs: 4_000_000_000) == nil)
    baseline.reset()
    #expect(baseline.rate(identity: "pid:new", counter: 1_000, monotonicNs: 10_000_000_000) == nil)
  }
  @Test func testMissingMetricsAndNonFiniteValuesNeverBecomeZero() throws {
    for status in [MetricStatus.unsupported, .warmingUp, .permissionDenied, .error] {
      let metric = Metric(
        value: 0, unit: "celsius", status: status, source: "fixture", sampledAt: Date(),
        intervalMs: 1_000)
      #expect(metric.value == nil)
      let json = try #require(
        JSONSerialization.jsonObject(with: JSONReport.encode(metric)) as? [String: Any])
      #expect(json["value"] is NSNull)
    }
    let nonFinite = Metric(
      value: .infinity, unit: "percent", status: .ok, source: "fixture", sampledAt: Date(),
      intervalMs: 1_000)
    #expect(nonFinite.status == .error)
    _ = try JSONReport.encode(nonFinite)
    let zero = Metric(
      value: 0, unit: "percent", status: .ok, source: "fixture", sampledAt: Date(),
      intervalMs: 1_000)
    #expect(zero.value == 0)
  }
  @Test func testStartTimeIsEncodedAsString() throws {
    let identity = ProcessIdentity(bootId: UUID(), pid: 42, startTime: "18446744073709551615")
    let data = try JSONReport.encode(identity)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["startTime"] as? String == identity.startTime)
  }
  @Test func testSQLiteIsEmbeddedAndRetryIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let segment = UUID()
    let path = directory.appendingPathComponent("probe.sqlite").path
    do {
      let database = try ProbeDatabase(path: path)
      for _ in 0..<2 {
        try database.commit(
          segment: segment, minute: 1, count: 60, coveredMs: 60_000, weightedSum: 600_000,
          minimum: 5, maximum: 15)
      }
      #expect(try database.rowCount() == 1)
      try database.checkpoint()
    }
    let reopened = try ProbeDatabase(path: path)
    #expect(try reopened.rowCount() == 1)
    #expect(ProbeDatabase.version == "3.53.4")
  }
  @Test func testMaintenanceOnlyAcceptsCompiledActions() {
    #expect(PrototypeAction(rawValue: "stop; touch /tmp/injected") == nil)
    #expect(PrototypeAction(rawValue: "arbitraryPath") == nil)
    for action in PrototypeAction.allCases {
      #expect(action.appleScript.contains(PrototypePaths.helper))
      #expect(action.arguments == [action.rawValue])
    }
  }
  @Test func testLaunchctlDisabledOverridesAreNeverTreatedAsEnabled() throws {
    for state in ["disabled", "true"] {
      #expect(
        try PrototypeStateParser.isDisabled(
          "disabled services = {\n \"org.cloudmacmonitor.probe\" => \(state)\n}"))
    }
    for state in ["enabled", "false"] {
      #expect(
        try PrototypeStateParser.isDisabled(
          "disabled services = {\n \"org.cloudmacmonitor.probe\" => \(state)\n}") == false)
    }
    #expect(
      try PrototypeStateParser.isDisabled("disabled services = {\n \"unrelated\" => disabled\n}")
        == false)
    #expect(throws: PrototypeStateError.self) {
      try PrototypeStateParser.isDisabled("permission denied")
    }
    #expect(throws: PrototypeStateError.self) {
      try PrototypeStateParser.isDisabled(
        "disabled services = {\n \"org.cloudmacmonitor.probe\" => unknown\n}")
    }
  }
}
