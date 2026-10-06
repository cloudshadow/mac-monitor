import Foundation
import HistoryStore
import MacCollectors
import MonitorCore

private struct PublishedMetrics {
  var snapshot: JSONValue = .object(["status": .string("warmingUp")])
  var apps: JSONValue = .object(["scanSequence": .string("0"), "rows": .array([])])
  var sorted: [String: [JSONValue]] = [:]
  var snapshotNs: UInt64 = 0, appsNs: UInt64 = 0, sequence: UInt64 = 0
  var encodedSnapshot = Data("{}".utf8), encodedApps = Data("{}".utf8)
  var intervals: [String: JSONValue] = [:]
}
public final class MetricStore: @unchecked Sendable {
  private let state = Locked(PublishedMetrics())
  private let system = BasicSystemCollector()
  private let io = IOCollector()
  private let applications: ApplicationCollector
  private let history: HistoryDatabase
  private var lastSystem: UInt64?, lastTemperature: UInt64?, lastGPU: UInt64?, lastApplications: UInt64?
  private var ownCPU = CounterBaseline()
  public let bootId: String
  public init(history: HistoryDatabase) {
    self.history = history
    let id = UUID().uuidString
    bootId = id
    applications = ApplicationCollector(bootId: id, identify: Crypto.hash)
  }
  public func reset() {
    system.reset()
    io.reset()
    applications.reset()
    lastSystem = nil
    lastTemperature = nil
    lastGPU = nil
    lastApplications = nil
    ownCPU.reset()
    history.startSegment()
  }
  public func collect(_ channel: Scheduler.Channel, interval: Int) {
    switch channel {
    case .system:
      let sample = system.sample(intervalMs: interval)
      guard let raw = try? JSONValue.from(sample), case .object(var snapshot) = raw else { return }
      if case .object(let values) = io.sample(intervalMs: interval) {
        snapshot.merge(values, uniquingKeysWith: { _, new in new })
      }
      for field in [
        "physicalMemoryBytes", "freeBytes", "speculativeBytes", "activeBytes", "inactiveBytes",
        "wiredBytes", "compressorBytes", "appMemoryBytes",
      ] { if snapshot[field] == nil { snapshot[field] = .null } }
      snapshot["bootId"] = .string(bootId)
      snapshot["recordingEpoch"] = .string(history.epoch)
      if let own = try? ProcessProbe.read(pid: Int32(ProcessInfo.processInfo.processIdentifier)) {
        let cpu = ownCPU.rate(
          identity: own.startTime, counter: own.cpuNs, monotonicNs: sample.monotonicNs
        ).map { $0 / 1e7 }
        snapshot["serviceOverhead"] = .object([
          "cpuPercentCore": cpu.map(JSONValue.number) ?? .null,
          "physicalFootprintBytes": .number(Double(own.footprintBytes)),
        ])
      }
      snapshot["schemaVersion"] = .number(1)
      snapshot["serverTime"] = .date(sample.sampledAt)
      snapshot["generatedAt"] = .date(sample.sampledAt)
      snapshot["ageMs"] = .number(0)
      snapshot["mode"] = .string(interval > 10000 ? "constrained" : "normal")
      snapshot["samplingPolicy"] = .object([
        "intervalMs": .number(Double(interval)),
        "reason": .string(interval > 10000 ? "powerOrThermalConstraint" : "default"),
      ])
      state.withLock { s in
        s.sequence += 1
        s.snapshotNs = sample.monotonicNs
        s.intervals["system"] = .number(Double(interval))
        snapshot["sequence"] = .string(String(s.sequence))
        snapshot["effectiveIntervals"] = .object(s.intervals)
        for field in ["temperature", "gpu", "sensors"] { snapshot[field] = s.snapshot[field] }
        s.snapshot = .object(snapshot)
        s.encodedSnapshot = (try? s.snapshot.data()) ?? Data("{}".utf8)
      }
      let duration = lastSystem.map { Double(sample.monotonicNs - $0) / 1e6 } ?? 0
      lastSystem = sample.monotonicNs
      var series: [String: Double] = [:]
      if let cpu = sample.cpu.value { series["cpu.total"] = cpu }
      if let memory = sample.nonIdlePercent.value { series["memory.nonIdle"] = memory }
      if let swap = sample.swapUsedBytes.value { series["memory.swapUsedBytes"] = swap }
      for field in [
        "networkReadBytesPerSecond", "networkWriteBytesPerSecond", "diskReadBytesPerSecond",
        "diskWriteBytesPerSecond",
      ] { if let value = snapshot[field]?["value"].number { series[field] = value } }
      history.ingest(
        series: series, at: sample.sampledAt.timeIntervalSince1970, durationMs: duration)
    case .apps:
      guard let table = try? applications.sample(intervalMs: interval) else { return }
      let rows = table["rows"].array
      var sorted: [String: [JSONValue]] = [:]
      for (sort, field) in [
        ("cpu", "cpuPercentCore"), ("memory", "physicalFootprintBytes"),
        ("diskRead", "diskReadBytesPerSecond"), ("diskWrite", "diskWriteBytesPerSecond"),
      ] {
        sorted[sort] = rows.sorted { a, b in
          let av = a[field].number ?? -1
          let bv = b[field].number ?? -1
          return av == bv ? (a["id"].string ?? "") < (b["id"].string ?? "") : av > bv
        }
      }
      state.withLock {
        $0.apps = table
        $0.sorted = sorted
        $0.appsNs = HardwareProbe.monotonicNs
        $0.intervals["apps"] = .number(Double(interval))
        $0.encodedApps = (try? Self.notification($0, age: 0).data()) ?? Data("{}".utf8)
      }
      let now = HardwareProbe.monotonicNs
      let duration = lastApplications.map { now >= $0 ? Double(now - $0) / 1e6 : 0 } ?? 0
      lastApplications = now
      history.ingestApps(table, durationMs: duration)
    case .temperature:
      let values = SensorCollector.temperatures(intervalMs: interval)
      let now = HardwareProbe.monotonicNs
      let duration = lastTemperature.map { Double(now - $0) / 1e6 } ?? 0
      lastTemperature = now
      var series: [String: Double] = [:]
      for sensor in values["sensors"].array {
        if let id = sensor["id"].string, let value = sensor["metric"]["value"].number {
          series["temperature:" + String(Crypto.hash(id).prefix(24))] = value
        }
      }
      history.ingest(series: series, at: Date().timeIntervalSince1970, durationMs: duration)
      state.withLock { s in
        guard case .object(var data) = s.snapshot else { return }
        data["temperature"] = values["metric"]
        data["sensors"] = .array(values["sensors"].array.map { sensor in
          guard case .object(var fields) = sensor, let id = fields["id"]?.string else { return sensor }
          fields["seriesId"] = .string("temperature:" + String(Crypto.hash(id).prefix(24)))
          return .object(fields)
        })
        s.intervals["temperature"] = .number(Double(interval))
        data["effectiveIntervals"] = .object(s.intervals)
        s.sequence += 1
        data["sequence"] = .string(String(s.sequence))
        s.snapshot = .object(data)
        s.encodedSnapshot = (try? s.snapshot.data()) ?? Data("{}".utf8)
      }
    case .gpu:
      let metric = SensorCollector.gpu(intervalMs: interval)
      let value = try? JSONValue.from(metric)
      let now = HardwareProbe.monotonicNs
      let duration = lastGPU.map { Double(now - $0) / 1e6 } ?? 0
      lastGPU = now
      if let value = metric.value {
        history.ingest(
          series: ["gpu.total": value], at: metric.sampledAt.timeIntervalSince1970,
          durationMs: duration)
      }
      state.withLock { s in
        guard case .object(var data) = s.snapshot else { return }
        data["gpu"] = value ?? .null
        s.intervals["gpu"] = .number(Double(interval))
        data["effectiveIntervals"] = .object(s.intervals)
        s.sequence += 1
        data["sequence"] = .string(String(s.sequence))
        s.snapshot = .object(data)
        s.encodedSnapshot = (try? s.snapshot.data()) ?? Data("{}".utf8)
      }
    }
  }
  public var snapshot: JSONValue {
    state.withLock { s in
      guard case .object(var data) = s.snapshot else { return s.snapshot }
      let now = HardwareProbe.monotonicNs
      data["serverTime"] = .date()
      data["ageMs"] = .number(now >= s.snapshotNs ? Double(now - s.snapshotNs) / 1e6 : 0)
      return .object(data)
    }
  }
  public var sampleSequence: String { state.withLock { String($0.sequence) } }
  public var appSequence: String { state.withLock { $0.apps["scanSequence"].string ?? "0" } }
  public var encodedSnapshot: Data { state.withLock { $0.encodedSnapshot } }
  public var encodedAppNotification: Data { state.withLock { $0.encodedApps } }
  private static func notification(_ s: PublishedMetrics, age: Double) -> JSONValue {
    .object([
      "bootId": s.apps["bootId"], "scanSequence": s.apps["scanSequence"],
      "sampledAt": s.apps["sampledAt"], "intervalMs": s.apps["intervalMs"], "ageMs": .number(age),
      "coverage": s.apps["coverage"],
    ])
  }

  public var appNotification: JSONValue {
    state.withLock { s in
      let now = HardwareProbe.monotonicNs
      return Self.notification(s, age: now >= s.appsNs ? Double(now - s.appsNs) / 1e6 : 0)
    }
  }
  public var capabilities: JSONValue {
    .object([
      "architecture": .string(HardwareProbe.architecture),
      "logicalCPUCount": .number(Double(ProcessInfo.processInfo.activeProcessorCount)),
      "temperature": .object(["verified": .bool(false)]),
      "gpu": .object(["verified": .bool(false)]),
      "samplingIntervals": .object(["system": .number(10000), "apps": .number(10000), "temperature": .number(10000), "gpu": .number(10000)]),
    ])
  }
  public func apps(
    sort: String, limit: Int, cursor: String?, query: String, sequence: String?,
    members: String? = nil
  ) throws -> JSONValue {
    guard (1...100).contains(limit), query.utf8.count <= 256 else {
      throw APIError(400, "invalidParameter")
    }
    return try state.withLock { s in
      let version = s.apps["scanSequence"].string ?? "0"
      if let sequence, sequence != version { throw APIError(409, "scanChanged") }
      let digest = String(Crypto.hash("\(sort):\(query):\(members ?? "")").prefix(16))
      var offset = 0
      if let cursor {
        let parts = cursor.split(separator: ":")
        guard parts.count == 3, parts[0] == Substring(version), parts[1] == Substring(digest),
          let number = Int(parts[2]), number >= 0, number <= 4096
        else { throw APIError(409, "scanChanged") }
        offset = number
      }
      let rows: [JSONValue]
      if let members {
        guard let app = s.apps["rows"].array.first(where: { $0["id"].string == members }) else {
          throw APIError(404, "appNotFound")
        }
        rows = app["members"].array
      } else {
        guard let sorted = s.sorted[sort] else { throw APIError(400, "invalidParameter") }
        rows =
          query.isEmpty
          ? sorted
          : sorted.filter { ($0["name"].string ?? "").localizedCaseInsensitiveContains(query) }
      }
      var page: [JSONValue] = []
      var bytes = 2048
      for row in rows.dropFirst(offset).prefix(limit) {
        var clean = row
        if members == nil, case .object(var object) = clean {
          object.removeValue(forKey: "members")
          clean = .object(object)
        }
        let size = (try clean.data()).count
        if bytes + size > 126 * 1024 { break }
        bytes += size
        page.append(clean)
      }
      let next =
        offset + page.count < rows.count
        ? JSONValue.string("\(version):\(digest):\(offset+page.count)") : .null
      return .object([
        "rows": .array(page), "total": .number(Double(rows.count)), "nextCursor": next,
        "scanSequence": .string(version), "sampledAt": s.apps["sampledAt"],
        "bootId": s.apps["bootId"], "coverage": s.apps["coverage"],
      ])
    }
  }
}
