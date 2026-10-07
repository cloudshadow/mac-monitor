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
    try await history.prepareStop()
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
  let start = try #require(before["rows"].array.first?["bucketStartUtc"].number)
  let overlapping = try await history.queryApps(from: start + 1, to: now + 1,
    limit: 100, cursor: nil, sort: "cpu")
  #expect(overlapping["rows"].array.count == before["rows"].array.count)
  _ = try await history.control("clear")
  try await history.prepareStop()
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

@Test func dayAndWeekQueriesAndCleanupHandleStoredHistory() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let history = HistoryDatabase(path: root.appendingPathComponent("history.sqlite").path)
  let fixture = try SQLite(path: history.path)
  let now = floor(Date().timeIntervalSince1970)
  let end = floor(now / 3600) * 3600
  try fixture.transaction {
    for res in [60, 300, 3600] {
      let count = 7 * 86400 / res
      try fixture.exec("WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i+1<\(count)) INSERT INTO buckets SELECT '1','fixture','cpu.total',\(res),\(end)-604800+i*\(res),\(end)-604800+(i+1)*\(res),25*\(res)*1000,\(res)*1000,1,25,25,0 FROM n")
    }
    try fixture.exec("WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i+1<10000) INSERT INTO app_buckets SELECT '1','fixture',\(end)-300*(i/10+1),'app-'||(i%10),json_object('id','app-'||(i%10),'name',printf('%02000d',i),'cpuPercentCore',i%10,'selectedBy',json_array('cpu','memory','disk'),'bucketStartUtc',\(end)-300*(i/10+1),'bucketEndUtc',\(end)-300*(i/10)) FROM n")
  }
  try fixture.checkpoint()
  let beforeBytes = history.storageBytes()
  #expect(beforeBytes > 1_000_000)
  // Keep recent samples present while querying persisted day/week data.
  history.recent.append([RecentBuffer.Point(epoch: history.epoch, segment: history.segment,
    series: "cpu.total", time: now, durationMs: 10000, value: 30, persisted: true)])
  for range in [86400.0, 604800.0] {
    let result = try await history.query(series: ["cpu.total"], from: now-range, to: now, maxPoints: 600)
    #expect(!result["series"]["cpu.total"].array.isEmpty)
    #expect(result["series"]["cpu.total"].array.count <= 600)
    let apps = try await history.queryApps(from: now-range, to: now, limit: 100, cursor: nil, sort: "cpu")
    #expect(apps["rows"].array.count == 100)
    let page = try await history.queryApps(from: now-range, to: now, limit: 100,
      cursor: apps["nextCursor"].string, sort: "cpu")
    #expect(page["rows"].array.count == 100)
    #expect(apps["rows"].array.first?["bucketStartUtc"] != page["rows"].array.first?["bucketStartUtc"])
  }
  _ = try await history.control("pause")
  _ = try await history.control("clear")
  try await history.prepareStop()
  #expect(history.storageBytes() < beforeBytes / 10)
  #expect(history.status()["state"].string == "paused")
  #expect(history.epoch == "2")
  #expect(try fixture.rows("SELECT * FROM buckets LIMIT 1").isEmpty)
  #expect(try fixture.rows("SELECT * FROM app_buckets LIMIT 1").isEmpty)
  _ = try await history.control("resume")
  #expect(history.enabled)
}

@Test func savedDataSizeIncludesHistoryAndSecretsWithoutFollowingLinks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root.appendingPathComponent("data/secrets"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(repeating: 0, count: 1024).write(to: root.appendingPathComponent("data/history.sqlite"))
  try Data(repeating: 0, count: 128).write(to: root.appendingPathComponent("data/secrets/ca.pem"))
  try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("outside"))
  try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/link"), withDestinationURL: root.appendingPathComponent("outside"))
  try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/directory-link"), withDestinationURL: root)
  #expect(AgentRuntime.savedDataBytes(root: root.appendingPathComponent("data").path) == 1152)
}
