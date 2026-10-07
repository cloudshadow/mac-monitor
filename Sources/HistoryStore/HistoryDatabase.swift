import CSQLite
import Foundation
import MonitorCore

private final class QueryDeadline { let value = DispatchTime.now().uptimeNanoseconds + 250_000_000 }
private struct HistoryState {
  var epoch = "1", enabled = true, segment = UUID().uuidString, error: String?, resetting = false,
    writeGeneration = 0, queuedBytes = 0, queries = 0, lastCommittedAt: Date?
}

public final class HistoryDatabase: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.cloudmacmonitor.history", qos: .utility)
  private var db: SQLite?
  private let state = Locked(HistoryState())
  public let recent = RecentBuffer()
  public let path: String
  private var buckets: [String: MetricBucket] = [:]
  private var appLimitReached = false
  private var appWindow: Double?, appSummary: [String: [String: JSONValue]] = [:]
  private var lastCleanup = Date.distantPast, lastCheckpoint = Date()
  public init(path: String) {
    self.path = path
    do {
      let existed = FileManager.default.fileExists(atPath: path)
      let connection = try SQLite(path: path)
      if existed {
        guard try connection.rows("PRAGMA quick_check").first?["quick_check"]?.string == "ok",
          try connection.rows("PRAGMA user_version").first?["user_version"]?.number == 1
        else { throw APIError(503, "historyRecoveryRequired") }
      } else {
        try connection.transaction {
          try connection.exec(
            "CREATE TABLE control(id INTEGER PRIMARY KEY CHECK(id=1), epoch INTEGER NOT NULL, enabled INTEGER NOT NULL, cleared_at REAL); INSERT INTO control VALUES(1,1,1,NULL); CREATE TABLE buckets(epoch TEXT NOT NULL,segment TEXT NOT NULL,series TEXT NOT NULL,res INTEGER NOT NULL,start REAL NOT NULL,end REAL NOT NULL,sum REAL NOT NULL,covered REAL NOT NULL,count INTEGER NOT NULL,min REAL NOT NULL,max REAL NOT NULL,partial INTEGER NOT NULL,PRIMARY KEY(epoch,segment,series,res,start)) WITHOUT ROWID; CREATE INDEX bucket_range ON buckets(epoch,series,res,start); CREATE TABLE app_buckets(epoch TEXT NOT NULL, segment TEXT NOT NULL, start REAL NOT NULL,app_id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(epoch,segment,start,app_id)) WITHOUT ROWID; PRAGMA user_version=1;"
          )
        }
      }
      _ = try connection.rows(
        "SELECT epoch,segment,series,res,start,end,sum,covered,count,min,max,partial FROM buckets LIMIT 0"
      )
      _ = try connection.rows("SELECT epoch,segment,start,app_id,body FROM app_buckets LIMIT 0")
      try connection.exec("CREATE INDEX IF NOT EXISTS app_range ON app_buckets(epoch,start,app_id); PRAGMA max_page_count=61440;")
      let control = try connection.rows(
        "SELECT CAST(epoch AS TEXT) AS epoch,enabled FROM control WHERE id=1"
      ).first
      guard let epoch = control?["epoch"]?.string else {
        throw APIError(503, "historyRecoveryRequired")
      }
      state.withLock {
        $0.epoch = epoch
        $0.enabled = control?["enabled"]?.number == 1
      }
      db = connection
    } catch {
      state.withLock {
        $0.error = "historyRecoveryRequired"
        $0.enabled = false
      }
    }
  }
  public var epoch: String { state.withLock { $0.epoch } }
  public var segment: String { state.withLock { $0.segment } }
  public var enabled: Bool { state.withLock { $0.enabled && $0.error == nil } }
  public func status() -> JSONValue {
    state.withLock { s in
      .object([
        "recordingEpoch": .string(s.epoch), "enabled": .bool(s.enabled),
        "state": .string(
          s.resetting ? "resetting" : s.error != nil ? "error" : s.enabled ? "recording" : "paused"),
        "lastCommittedAt": s.lastCommittedAt.map(JSONValue.date) ?? .null,
        "diskBytes": .number(Double(storageBytes())),
        "recentBytes": .number(Double(recent.allocatedBytes)),
        "systemRetentionDays": .number(30), "appRetentionDays": .number(7),
        "error": s.error.map(JSONValue.string) ?? .null,
      ])
    }
  }
  public func storageBytes() -> UInt64 {
    [path, path + "-wal", path + "-shm"].reduce(0) {
      $0
        + (((try? FileManager.default.attributesOfItem(atPath: $1)[.size]) as? NSNumber)?
          .uint64Value ?? 0)
    }
  }
  public func ingest(series: [String: Double], at: Double, durationMs: Double) {
    let captured = state.withLock { $0 }
    guard !captured.resetting, durationMs > 0, durationMs <= 30_000 else { return }
    let points = series.prefix(64).compactMap { key, value in
      value.isFinite
        ? RecentBuffer.Point(
          epoch: captured.epoch, segment: captured.segment, series: key, time: at,
          durationMs: durationMs, value: value, persisted: captured.enabled && captured.error == nil
        ) : nil
    }
    state.withLock { s in if s.epoch == captured.epoch && !s.resetting { recent.append(points) } }
    guard captured.enabled, captured.error == nil else { return }
    let size = points.count * 512
    let accepted = state.withLock { s in
      guard s.queuedBytes + size <= 2 * 1_024 * 1_024 else {
        s.error = "historyQueueFull"
        return false
      }
      s.queuedBytes += size
      return true
    }
    guard accepted else { return }
    queue.async { [self] in
      defer { state.withLock { $0.queuedBytes -= size } }
      guard captured.epoch == epoch,
        state.withLock({
          !$0.resetting && $0.writeGeneration == captured.writeGeneration && $0.enabled
        }), let db
      else { return }
      do {
        // Finalize previous minutes before placing new samples into a new minute.
        let minute = floor(at / 60) * 60
        for p in points {
          var left = p.time - p.durationMs / 1000
          while left < p.time {
            let start = floor(left / 60) * 60
            let end = Swift.min(start + 60, p.time)
            let ms = (end - left) * 1000
            let key = "\(p.segment):\(p.series):\(start)"
            var b =
              buckets[key]
              ?? MetricBucket(
                segmentId: p.segment, seriesId: p.series, recordingEpoch: p.epoch,
                bucketStartUtc: start, bucketEndUtc: start + 60, resolutionSeconds: 60,
                sourceResolutionSeconds: 60, weightedSum: 0, coveredDurationMs: 0, sampleCount: 0,
                min: p.value, max: p.value, partial: true)
            b.weightedSum += p.value * ms
            b.coveredDurationMs += ms
            b.sampleCount += 1
            b.min = Swift.min(b.min, p.value)
            b.max = Swift.max(b.max, p.value)
            b.partial = b.coveredDurationMs < 59_000
            buckets[key] = b
            left = end
          }
        }
        try flush(before: minute, db: db, series: Set(points.map(\.series)))
        try flush(before: minute - 60, db: db)
        try maintain(db)
      } catch {
        state.withLock { current in
          if !current.resetting && current.epoch == captured.epoch {
            current.error = (error as? APIError)?.code ?? "historyWriteFailed"
          }
        }
        buckets.removeAll()
      }
    }
  }
  public func ingestApps(_ table: JSONValue, durationMs: Double) {
    let captured = state.withLock { $0 }
    let time = Date().timeIntervalSince1970
    let rows = table["rows"].array.map { row -> JSONValue in
      guard case .object(var value) = row else { return row }
      value.removeValue(forKey: "members")
      return .object(value)
    }
    let fields = [
      "cpuPercentCore", "physicalFootprintBytes", "diskReadBytesPerSecond",
      "diskWriteBytesPerSecond",
    ]
    var retained = Set<String>()
    for category in ["cpu", "memory", "disk"] {
      func score(_ row: JSONValue) -> Double {
        switch category {
        case "cpu": return row["cpuPercentCore"].number ?? -1
        case "memory": return row["physicalFootprintBytes"].number ?? -1
        default:
          guard
            row["diskReadBytesPerSecond"].number != nil
              || row["diskWriteBytesPerSecond"].number != nil
          else { return -1 }
          return (row["diskReadBytesPerSecond"].number ?? 0)
            + (row["diskWriteBytesPerSecond"].number ?? 0)
        }
      }
      for row in rows.sorted(by: { score($0) > score($1) }).prefix(10) {
        if let id = row["id"].string { retained.insert(id) }
      }
    }
    let selected = rows.filter { retained.contains($0["id"].string ?? "") }.map {
      row -> JSONValue in
      guard case .object(var value) = row else { return row }
      value.removeValue(forKey: "members")
      return .object(value)
    }
    state.withLock { current in
      if current.epoch == captured.epoch && !current.resetting {
        recent.appendApps(
          at: time,
          frame: .object([
            "recordingEpoch": .string(captured.epoch), "sampledAt": .number(time),
            "rows": .array(selected), "coverage": table["coverage"],
          ]))
      }
    }
    guard durationMs.isFinite, durationMs > 0, durationMs <= 30_000,
      captured.enabled, captured.error == nil, !captured.resetting else { return }
    let size = (try? JSONValue.array(rows).data().count) ?? 2 * 1024 * 1024
    let accepted = state.withLock { current in
      guard current.queuedBytes + size <= 2 * 1024 * 1024 else {
        current.error = "historyQueueFull"
        return false
      }
      current.queuedBytes += size
      return true
    }
    guard accepted else { return }
    queue.async { [self] in
      defer { state.withLock { $0.queuedBytes -= size } }
      guard captured.epoch == epoch,
        state.withLock({
          !$0.resetting && $0.writeGeneration == captured.writeGeneration && $0.enabled
        }), let db
      else { return }
      do {
        let window = floor(time / 300) * 300
        if let previous = appWindow, previous != window {
          try flushApps(db, epoch: captured.epoch, segment: captured.segment)
          appSummary.removeAll()
          appLimitReached = false
        }
        appWindow = window
        for row in rows {
          guard let id = row["id"].string else { continue }
          guard appSummary[id] != nil || appSummary.count < 4096 else {
            appLimitReached = true
            continue
          }
          var summary =
            appSummary[id] ?? [
              "id": .string(id), "name": row["name"], "coveredDurationMs": .number(0),
              "samples": .number(0),
            ]
          summary["coveredDurationMs"] = .number(
            (summary["coveredDurationMs"]?.number ?? 0) + durationMs)
          summary["samples"] = .number((summary["samples"]?.number ?? 0) + 1)
          for field in fields {
            if let value = row[field].number {
              summary[field + "Sum"] = .number(
                (summary[field + "Sum"]?.number ?? 0) + value * durationMs)
              summary[field + "Covered"] = .number(
                (summary[field + "Covered"]?.number ?? 0) + durationMs)
              summary[field + "Min"] = .number(min(summary[field + "Min"]?.number ?? value, value))
              summary[field + "Max"] = .number(max(summary[field + "Max"]?.number ?? value, value))
            }
          }
          appSummary[id] = summary
        }
      } catch {
        state.withLock { current in
          if !current.resetting && current.epoch == captured.epoch {
            current.error = "historyWriteFailed"
          }
        }
        appSummary.removeAll()
        appLimitReached = false
      }
    }
  }
  private func flushApps(_ db: SQLite, epoch: String, segment: String) throws {
    guard let start = appWindow, !appSummary.isEmpty else { return }
    let sorts = [
      ("cpu", "cpuPercentCore"), ("memory", "physicalFootprintBytes"),
      ("disk", "diskReadBytesPerSecond"),
    ]
    var selected: [String: [String]] = [:]
    func score(_ row: [String: JSONValue], _ field: String) -> Double {
      let sum = row[field + "Sum"]?.number ?? 0
      let covered = row[field + "Covered"]?.number ?? 0
      return covered > 0 ? sum / covered : -1
    }
    for (label, field) in sorts {
      func rank(_ row: [String: JSONValue]) -> Double {
        switch label {
        case "memory": return row[field + "Max"]?.number ?? -1
        case "disk":
          return (row["diskReadBytesPerSecondSum"]?.number ?? 0)
            + (row["diskWriteBytesPerSecondSum"]?.number ?? 0)
        default: return score(row, field)
        }
      }
      for (id, _) in appSummary.sorted(by: { a, b in
        let av = rank(a.value), bv = rank(b.value)
        return av == bv ? a.key < b.key : av > bv
      }).prefix(10) { selected[id, default: []].append(label) }
    }
    try db.transaction {
      for (id, by) in selected {
        var row = appSummary[id]!
        row["coverage"] = .object(["identityLimitReached": .bool(appLimitReached)])
        row["status"] = .string(appLimitReached ? "partial" : "ok")
        row["selectedBy"] = .array(by.map(JSONValue.string))
        row["physicalFootprintPeakBytes"] = row["physicalFootprintBytesMax"] ?? .null
        row["diskReadBytes"] = .number((row["diskReadBytesPerSecondSum"]?.number ?? 0) / 1000)
        row["diskWriteBytes"] = .number((row["diskWriteBytesPerSecondSum"]?.number ?? 0) / 1000)
        row["bucketStartUtc"] = .number(start)
        row["bucketEndUtc"] = .number(start + 300)
        for (_, field) in sorts + [("write", "diskWriteBytesPerSecond")] {
          let value = score(row, field)
          row[field] = value >= 0 ? .number(value) : .null
        }
        let body = String(data: try JSONValue.object(row).data(), encoding: .utf8)!
        try db.run(
          "INSERT OR REPLACE INTO app_buckets VALUES(?,?,?,?,?)",
          [.string(epoch), .string(segment), .number(start), .string(id), .string(body)])
      }
    }
  }
  public func queryApps(
    from: Double, to: Double, limit: Int, cursor: String?, sort: String, recentOnly: Bool = false, appId: String? = nil
  ) async throws -> JSONValue {
    let captured = epoch
    guard !state.withLock({ $0.resetting }) else { throw APIError(503, "historyResetting") }
    guard appId == nil || (appId!.utf8.count <= 256 && !appId!.isEmpty) else { throw APIError(400, "invalidParameter") }
    guard to <= Date().timeIntervalSince1970 + 60, from < to,
      to - from <= (recentOnly ? 300 : 7 * 86400), (1...100).contains(limit),
      ["cpu", "memory", "disk"].contains(sort)
    else { throw APIError(400, "invalidParameter") }
    let digest = String(CryptoFreeHash.key("\(from):\(to):\(sort):\(appId ?? "")").prefix(16))
    var offset = 0
    if let cursor {
      let parts = cursor.split(separator: ":")
      guard parts.count == 3, parts[0] == Substring(captured), parts[1] == Substring(digest),
        let number = Int(parts[2]), number >= 0, number <= 100000
      else { throw APIError(409, "historyChanged") }
      offset = number
    }
    if recentOnly {
      let frames = recent.apps(from: from, to: to, epoch: captured)
      let flattened = frames.flatMap { frame in
        frame["rows"].array.filter { appId == nil || $0["id"].string == appId }.map { row -> JSONValue in
          guard case .object(var value) = row else { return row }
          value["sampledAt"] = frame["sampledAt"]
          value["source"] = .string("memory")
          return .object(value)
        }
      }
      return .object([
        "recordingEpoch": .string(captured),
        "rows": .array(Array(flattened.dropFirst(offset).prefix(limit))),
        "notRetained": .bool(appId != nil && flattened.isEmpty),
        "nextCursor": offset + limit < flattened.count
          ? .string("\(captured):\(digest):\(offset+limit)") : .null, "recordingStatus": status(),
      ])
    }
    try state.withLock { value in
      guard value.queries < 3 else { throw APIError(429, "queryQueueFull") }
      value.queries += 1
    }
    defer { state.withLock { $0.queries -= 1 } }
    let pageOffset = offset
    let sortField = [
      "cpu": "cpuPercentCore", "memory": "physicalFootprintPeakBytes", "disk": "diskReadBytes",
    ][sort]!
    let sortExpression = sort == "disk"
      ? "(COALESCE(json_extract(body,'$.diskReadBytes'),0)+COALESCE(json_extract(body,'$.diskWriteBytes'),0))"
      : "json_extract(body,'$.\(sortField)')"
    let response = try await work { db -> JSONValue in
      let deadline = QueryDeadline()
      sqlite3_progress_handler(
        db.handle, 1000,
        { pointer in
          guard let pointer else { return 1 }
          return DispatchTime.now().uptimeNanoseconds
            > Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue().value ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
      defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
      let values = try db.rows(
        "SELECT body,segment FROM app_buckets WHERE epoch=? AND start>? AND start<? AND (? IS NULL OR app_id=?) ORDER BY start DESC,\(sortExpression) DESC,app_id LIMIT ? OFFSET ?",
        [
          .string(captured), .number(from - 300), .number(to), appId.map(JSONValue.string) ?? .null,
          appId.map(JSONValue.string) ?? .null, .number(Double(limit + 1)),
          .number(Double(pageOffset)),
        ], limit: limit + 1)
      let rows = try values.prefix(limit).map { value -> JSONValue in
        guard let body = value["body"]?.string, let segment = value["segment"]?.string,
          case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        else { throw APIError(503, "historyUnavailable") }
        object["segmentId"] = .string(segment)
        return .object(object)
      }
      return .object([
        "recordingEpoch": .string(captured), "rows": .array(rows),
        "notRetained": .bool(appId != nil && rows.isEmpty),
        "truncated": .bool(from < Date().timeIntervalSince1970 - 7 * 86400),
        "nextCursor": values.count > limit
          ? .string("\(captured):\(digest):\(pageOffset+limit)") : .null,
        "recordingStatus": self.status(),
      ])
    }
    guard epoch == captured else { throw APIError(409, "historyChanged") }
    return response
  }
  private func flush(before time: Double, db: SQLite, series: Set<String>? = nil) throws {
    let completed = buckets.filter {
      $0.value.bucketStartUtc < time && (series == nil || series!.contains($0.value.seriesId))
    }
    guard !completed.isEmpty else { return }
    try db.transaction {
      for b in completed.values {
        guard b.recordingEpoch == epoch else { continue }
        try db.run(
          "INSERT INTO buckets VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(epoch,segment,series,res,start) DO UPDATE SET end=excluded.end,sum=excluded.sum,covered=excluded.covered,count=excluded.count,min=excluded.min,max=excluded.max,partial=excluded.partial",
          [
            .string(b.recordingEpoch), .string(b.segmentId), .string(b.seriesId), .number(60),
            .number(b.bucketStartUtc), .number(b.bucketEndUtc), .number(b.weightedSum),
            .number(b.coveredDurationMs), .number(Double(b.sampleCount)), .number(b.min),
            .number(b.max), .bool(b.partial),
          ])
        for res in [300, 3_600] {
          let start = floor(b.bucketStartUtc / Double(res)) * Double(res)
          try db.run(
            "INSERT OR REPLACE INTO buckets SELECT epoch,segment,series,?, ?, ?,SUM(sum),SUM(covered),SUM(count),MIN(min),MAX(max),(MAX(partial) OR SUM(covered)<?) FROM buckets WHERE epoch=? AND segment=? AND series=? AND res=60 AND start>=? AND start<? GROUP BY epoch,segment,series",
            [
              .number(Double(res)), .number(start), .number(start + Double(res)),
              .number(Double(res) * 1000), .string(b.recordingEpoch), .string(b.segmentId),
              .string(b.seriesId), .number(start), .number(start + Double(res)),
            ])
        }
      }
    }
    for key in completed.keys { buckets.removeValue(forKey: key) }
    state.withLock { $0.lastCommittedAt = Date() }
  }
  private func maintain(_ db: SQLite) throws {
    let now = Date()
    let bytes = storageBytes()
    if now.timeIntervalSince(lastCheckpoint) >= 300
      || ((try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?
        .uint64Value ?? 0) >= 4 * 1_024 * 1_024
    {
      try db.checkpoint()
      lastCheckpoint = now
    }
    if now.timeIntervalSince(lastCleanup) >= 3_600 || bytes >= 240 * 1_024 * 1_024 {
      let time = now.timeIntervalSince1970
      for (res, days) in [(60, 1), (300, 7), (3_600, 30)] {
        try db.run(
          "DELETE FROM buckets WHERE (epoch,segment,series,res,start) IN (SELECT epoch,segment,series,res,start FROM buckets WHERE (epoch<>? OR (res=? AND end<?)) LIMIT 512)",
          [.string(epoch), .number(Double(res)), .number(time - Double(days) * 86_400)])
      }
      try db.run(
        "DELETE FROM app_buckets WHERE (epoch,segment,start,app_id) IN (SELECT epoch,segment,start,app_id FROM app_buckets WHERE epoch<>? OR start<? LIMIT 128)",
        [.string(epoch), .number(time - 7 * 86_400)])
      lastCleanup = now
    }
    if bytes >= 256 * 1_024 * 1_024
      || ((try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?
        .uint64Value ?? 0) > 8 * 1_024 * 1_024
    {
      throw APIError(503, "historyCapacityExceeded")
    }
  }
  public func startSegment() {
    let old = state.withLock { current in
      let previous = (current.epoch, current.segment)
      current.segment = UUID().uuidString
      return previous
    }
    queue.async { [self] in
      guard let db else { return }
      do {
        try flush(before: .infinity, db: db)
        try flushApps(db, epoch: old.0, segment: old.1)
        appSummary.removeAll()
        appLimitReached = false
        appWindow = nil
      } catch { state.withLock { $0.error = "historyWriteFailed" } }
    }
  }
  public func boundary() async throws {
    try await work { [self] db in
      try flush(before: .infinity, db: db)
      try flushApps(db, epoch: epoch, segment: segment)
      appSummary.removeAll()
      appLimitReached = false
      appWindow = nil
      state.withLock { $0.segment = UUID().uuidString }
    }
  }
  public func prepareStop() async throws {
    try await work { [self] db in
      try flush(before: .infinity, db: db)
      try flushApps(db, epoch: epoch, segment: segment)
      try db.checkpoint()
    }
  }
  public func control(_ command: String) async throws -> JSONValue {
    if command == "clear" {
      try state.withLock {
        guard !$0.resetting else { throw APIError(503, "historyResetting") }
        $0.resetting = true
      }
      if let db { sqlite3_interrupt(db.handle) }
    }
    do {
      try await work { [self] db in
        switch command {
        case "pause":
          try flush(before: .infinity, db: db)
          try flushApps(db, epoch: epoch, segment: segment)
          appSummary.removeAll()
          appLimitReached = false
          appWindow = nil
          try db.run("UPDATE control SET enabled=0 WHERE id=1")
          state.withLock {
            $0.enabled = false
            $0.writeGeneration += 1
            $0.segment = UUID().uuidString
          }
        case "resume":
          try db.run("UPDATE control SET enabled=1 WHERE id=1")
          buckets.removeAll()
          state.withLock {
            $0.enabled = true
            $0.writeGeneration += 1
            $0.error = nil
            $0.segment = UUID().uuidString
          }
        case "clear":
          buckets.removeAll()
          appSummary.removeAll()
          appLimitReached = false
          appWindow = nil
          try db.transaction {
            try db.run(
              "UPDATE control SET epoch=epoch+1,cleared_at=? WHERE id=1",
              [.number(Date().timeIntervalSince1970)])
          }
          let newEpoch =
            try db.rows("SELECT CAST(epoch AS TEXT) AS epoch FROM control").first?["epoch"]?.string
            ?? ""
          state.withLock {
            $0.epoch = newEpoch
            $0.writeGeneration += 1
            $0.segment = UUID().uuidString
          }
          recent.clear()
          scheduleReclaim()
        default: throw APIError(400, "invalidCommand")
        }
      }
    } catch {
      if command == "clear" { state.withLock { $0.resetting = false } }
      throw error
    }
    return status()
  }
  private func scheduleReclaim() {
    queue.async { [self] in
      defer { state.withLock { $0.resetting = false } }
      guard let db else { return }
      do {
        try db.transaction {
          try db.run("DELETE FROM buckets WHERE epoch<>?", [.string(epoch)])
          try db.run("DELETE FROM app_buckets WHERE epoch<>?", [.string(epoch)])
        }
        try db.checkpoint()
        try db.exec("VACUUM")
        try db.checkpoint()
        state.withLock { $0.error = nil }
      } catch { state.withLock { $0.error = "historyCleanupFailed" } }
    }
  }
  private func work<T: Sendable>(_ body: @escaping @Sendable (SQLite) throws -> T) async throws -> T
  {
    try await withCheckedThrowingContinuation { c in
      queue.async { [self] in
        guard let db else {
          c.resume(throwing: APIError(503, "historyRecoveryRequired"))
          return
        }
        do { c.resume(returning: try body(db)) } catch { c.resume(throwing: error) }
      }
    }
  }
  private func decodeBucket(
    _ row: [String: JSONValue], series: String, epoch: String, resolution: Int
  ) throws -> MetricBucket {
    guard let segment = row["segment"]?.string, let start = row["start"]?.number,
      let end = row["end"]?.number, let sum = row["sum"]?.number,
      let covered = row["covered"]?.number, let count = row["count"]?.number,
      let low = row["min"]?.number, let high = row["max"]?.number,
      let partial = row["partial"]?.number,
      [start, end, sum, covered, count, low, high].allSatisfy({ $0.isFinite }), start < end,
      covered >= 0, count >= 0, count < Double(Int.max), count.rounded(.down) == count, low <= high
    else { throw APIError(503, "historyRecoveryRequired") }
    return MetricBucket(
      segmentId: segment, seriesId: series, recordingEpoch: epoch, bucketStartUtc: start,
      bucketEndUtc: end, resolutionSeconds: resolution, sourceResolutionSeconds: resolution,
      weightedSum: sum, coveredDurationMs: covered, sampleCount: Int(count), min: low, max: high,
      partial: partial == 1)
  }
  public func query(series: [String], from: Double, to: Double, maxPoints: Int) async throws
    -> JSONValue
  {
    let now = Date().timeIntervalSince1970
    let captured = epoch
    guard !state.withLock({ $0.resetting }) else { throw APIError(503, "historyResetting") }
    guard from < to, to - from <= 30 * 86_400, to <= now + 60, !series.isEmpty, series.count <= 8,
      series.allSatisfy({ $0.utf8.count <= 128 }), (1...600).contains(maxPoints)
    else { throw APIError(400, "invalidParameter") }
    try state.withLock { s in
      guard s.queries < 3 else { throw APIError(429, "queryQueueFull") }
      s.queries += 1
    }
    defer { state.withLock { $0.queries -= 1 } }
    let response: JSONValue = try await work { [self] db in
      let deadline = QueryDeadline()
      sqlite3_progress_handler(
        db.handle, 1_000,
        { pointer in
          guard let pointer else { return 1 }
          return DispatchTime.now().uptimeNanoseconds
            > Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue().value ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
      defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
      var result: [String: JSONValue] = [:]
      for id in Array(Set(series)).sorted() {
        let memory = recent.read(series: id, from: from, to: to, epoch: captured)
        let split = memory.first.map { floor(($0.time - $0.durationMs / 1000) / 60) * 60 } ?? to
        var points: [MetricBucket] = []
        let hourBoundary = ceil((now - 7 * 86_400) / 3600) * 3600
        let minuteBoundary = ceil((now - 86_400) / 300) * 300
        for (res, lower, upper) in [
          (3_600, now - 30 * 86_400, hourBoundary), (300, hourBoundary, minuteBoundary),
          (60, minuteBoundary, to),
        ] {
          let start = Swift.max(from, lower)
          let end = Swift.min(to, upper, split)
          guard start < end else { continue }
          let rows = try db.rows(
            "SELECT * FROM buckets WHERE epoch=? AND series=? AND res=? AND end>? AND start<? ORDER BY segment,start",
            [.string(captured), .string(id), .number(Double(res)), .number(start), .number(end)],
            limit: 12_000)
          for r in rows {
            points.append(try decodeBucket(r, series: id, epoch: captured, resolution: res))
          }
        }
        // Only substitute memory when the complete overlapping minute is actually retained.
        if let first = memory.first {
          let boundary = floor((first.time - first.durationMs / 1000) / 60) * 60
          let fallback = try db.rows(
            "SELECT * FROM buckets WHERE epoch=? AND series=? AND res=60 AND end>? AND start>=? AND start<? ORDER BY segment,start",
            [
              .string(captured), .string(id), .number(from), .number(boundary),
              .number(Swift.min(to, first.time)),
            ], limit: 16)
          if first.time - first.durationMs / 1000 > boundary + 0.01 {
            for r in fallback {
              var point = try decodeBucket(r, series: id, epoch: captured, resolution: 60)
              point.partial = true
              points.append(point)
            }
          }
        }
        let dbEndBySegment = Dictionary(grouping: points, by: \.segmentId).mapValues {
          $0.map(\.bucketEndUtc).max() ?? from
        }
        for p in memory where p.time - p.durationMs / 1000 >= (dbEndBySegment[p.segment] ?? from) {
          var b = MetricBucket(
            segmentId: p.segment, seriesId: id, recordingEpoch: captured,
            bucketStartUtc: p.time - p.durationMs / 1000, bucketEndUtc: p.time,
            resolutionSeconds: Swift.max(1, Int((p.durationMs / 1000).rounded())),
            sourceResolutionSeconds: Swift.max(1, Int((p.durationMs / 1000).rounded())),
            weightedSum: p.value * p.durationMs,
            coveredDurationMs: p.durationMs, sampleCount: 1, min: p.value, max: p.value,
            partial: false)
          b.source = "memory"
          b.persisted = p.persisted
          points.append(b)
        }
        result[id] = .array(
          try HistoryAggregation.coalesce(
            points, maxPoints: maxPoints, from: from, to: to, deadlineNs: deadline.value
          ).map(
            \.json))
      }
      return .object([
        "recordingEpoch": .string(captured), "series": .object(result),
        "effectiveRange": .object(["from": .number(from), "to": .number(to)]),
        "truncated": .bool(false), "recordingStatus": status(),
      ])
    }
    guard captured == epoch else { throw APIError(409, "historyChanged") }
    return response
  }
}

private enum CryptoFreeHash {
  static func key(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
  }
}
