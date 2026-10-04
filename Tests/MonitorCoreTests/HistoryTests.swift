import Foundation
import MonitorCore
import Testing

@testable import HistoryStore
@testable import MonitorServer

@Suite struct HistoryTests {
  func bucket(
    _ start: Double, _ value: Double, _ covered: Double = 3_600_000, segment: String = "a"
  ) -> MetricBucket {
    MetricBucket(
      segmentId: segment, seriesId: "cpu.total", recordingEpoch: "1", bucketStartUtc: start,
      bucketEndUtc: start + 3600, resolutionSeconds: 3600, sourceResolutionSeconds: 3600,
      weightedSum: value * covered, coveredDurationMs: covered, sampleCount: 60, min: value,
      max: value, partial: covered < 3_600_000)
  }
  @Test func thirtyDaysFitWithoutTruncation() throws {
    let source = (0..<720).map { bucket(Double($0) * 3600, Double($0 % 100)) }
    let result = try HistoryAggregation.coalesce(source, maxPoints: 600, from: 0, to: 720 * 3600)
    #expect(result.count == 360)
    #expect(result.reduce(0) { $0 + $1.sampleCount } == 720 * 60)
    #expect(abs((result.last?.bucketEndUtc ?? -1) - 2592000.0) < 0.001)
  }
  @Test func weightedMeanPreservesExtremaAndGaps() throws {
    let result = try HistoryAggregation.coalesce(
      [bucket(0, 10), bucket(3600, 90, 1_800_000)], maxPoints: 1, from: 0, to: 7200)
    #expect(result.count == 1)
    #expect(abs(result[0].avg - 36.6666667) < 0.0001)
    #expect(result[0].min == 10 && result[0].max == 90)
    do {
      _ = try HistoryAggregation.coalesce(
        [bucket(0, 10), bucket(7200, 90)], maxPoints: 1, from: 0, to: 10800)
      Issue.record("merged across gap")
    } catch let e as APIError { #expect(e.code == "pointBudgetTooSmall") }
    do {
      _ = try HistoryAggregation.coalesce(
        [bucket(0, 10), bucket(3600, 90, segment: "b")], maxPoints: 1, from: 0, to: 7200)
      Issue.record("merged across segment")
    } catch let e as APIError { #expect(e.code == "pointBudgetTooSmall") }
  }
  @Test func clearPauseAndRestartPreserveEpochBarrier() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = HistoryDatabase(path: root.appendingPathComponent("history.sqlite").path)
    let now = Date().timeIntervalSince1970
    for i in 0..<70 {
      history.ingest(series: ["cpu.total": 25], at: now - 70 + Double(i), durationMs: 1000)
    }
    try await history.prepareStop()
    let before = try await history.query(
      series: ["cpu.total"], from: now - 100, to: now, maxPoints: 100)
    #expect(!before["series"]["cpu.total"].array.isEmpty)
    _ = try await history.control("pause")
    history.ingest(series: ["cpu.total": 30], at: now, durationMs: 1000)
    _ = try await history.control("clear")
    #expect(history.epoch == "2")
    #expect(history.recent.allocatedBytes == 0)
    let after = try await history.query(
      series: ["cpu.total"], from: now - 100, to: now, maxPoints: 100)
    #expect(after["series"]["cpu.total"].array.isEmpty)
    let reopened = HistoryDatabase(path: history.path)
    #expect(reopened.epoch == "2")
    #expect(!reopened.enabled)
    _ = try await history.control("resume")
    #expect(history.enabled)
  }
  @Test func viewersAreBoundAndLimited() throws {
    let a = AccountSession(
      hash: "a", epoch: 1, lan: false, expiresAt: Date().addingTimeInterval(100))
    let b = AccountSession(
      hash: "b", epoch: 1, lan: false, expiresAt: Date().addingTimeInterval(100))
    let service = ViewerService()
    let ids = try (0..<6).map { _ in
      try service.create(session: a, channels: ["system"])["viewerId"].string!
    }
    #expect(throws: APIError.self) { try service.create(session: a, channels: ["system"]) }
    #expect(throws: APIError.self) { try service.open(ids[0], session: b) }
    for id in ids.prefix(3) { try service.open(id, session: a) }
    #expect(throws: APIError.self) { try service.open(ids[3], session: a) }
    service.close(ids[0])
    try service.open(ids[3], session: a)
  }
}

@Test func finalApplicationTopUnionIsBoundedAndClearInvalidatesIt() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let history = HistoryDatabase(path: root.appendingPathComponent("history.sqlite").path)
  let rows: [JSONValue] = (0..<40).map { i -> JSONValue in
    let disk: Double = i >= 10 && i < 20 ? 1000 : 0
    let fields: [String: JSONValue] = [
      "id": .string("app-\(i)"), "name": .string("App \(i)"), "cpuPercentCore": .number(Double(i)),
      "physicalFootprintBytes": .number(Double(40 - i)), "diskReadBytesPerSecond": .number(disk),
      "diskWriteBytesPerSecond": .number(0),
    ]
    return .object(fields)
  }
  history.ingestApps(.object(["rows": .array(rows)]), durationMs: 4000)
  try await history.prepareStop()
  let now = Date().timeIntervalSince1970
  let before = try await history.queryApps(
    from: now - 500, to: now + 1, limit: 100, cursor: nil, sort: "cpu")
  #expect(before["rows"].array.count == 30)
  #expect(before["rows"].array.allSatisfy { !$0["selectedBy"].array.isEmpty })
  _ = try await history.control("clear")
  let after = try await history.queryApps(
    from: now - 500, to: now + 1, limit: 100, cursor: nil, sort: "cpu")
  #expect(after["rows"].array.isEmpty)
}

@Test func applicationTopUsesMemoryPeakAndDiskIncrement() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let history = HistoryDatabase(path: root.appendingPathComponent("history.sqlite").path)
  func row(_ id: String, memory: Double, disk: Double) -> JSONValue {
    .object(["id": .string(id), "name": .string(id), "cpuPercentCore": .number(100),
      "physicalFootprintBytes": .number(memory), "diskReadBytesPerSecond": .number(disk),
      "diskWriteBytesPerSecond": .number(0)])
  }
  let incumbents = (0..<10).map { row("base-\($0)", memory: 1000, disk: 1000) }
  history.ingestApps(.object(["rows": .array(incumbents + [row("peak", memory: 2000, disk: 0)])]), durationMs: 1)
  history.ingestApps(.object(["rows": .array([row("peak", memory: 0, disk: 0), row("volume", memory: 0, disk: 1)])]), durationMs: 30_000)
  try await history.prepareStop()
  let now = Date().timeIntervalSince1970
  let result = try await history.queryApps(from: now - 500, to: now + 1, limit: 100, cursor: nil, sort: "cpu")
  let peak = try #require(result["rows"].array.first { $0["id"].string == "peak" })
  #expect(peak["selectedBy"].array.contains(.string("memory")))
  #expect(peak["physicalFootprintPeakBytes"].number == 2000)
  let volume = try #require(result["rows"].array.first { $0["id"].string == "volume" })
  #expect(volume["selectedBy"].array.contains(.string("disk")))
  #expect(volume["diskReadBytes"].number == 30)
  let filtered = try await history.queryApps(from: now - 500, to: now + 1, limit: 100, cursor: nil, sort: "memory", appId: "peak")
  #expect(filtered["rows"].array.count == 1)
  let missing = try await history.queryApps(from: now - 500, to: now + 1, limit: 100, cursor: nil, sort: "cpu", appId: "absent")
  #expect(missing["notRetained"].bool == true)
  #expect(missing["rows"].array.isEmpty)
}
