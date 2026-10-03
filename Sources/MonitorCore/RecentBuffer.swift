import Foundation

public final class RecentBuffer: @unchecked Sendable {
  public struct Point: Codable, Sendable {
    public let epoch: String, segment: String, series: String
    public let time: Double, durationMs: Double, value: Double, persisted: Bool
    public init(
      epoch: String, segment: String, series: String, time: Double, durationMs: Double,
      value: Double, persisted: Bool
    ) {
      self.epoch = epoch
      self.segment = segment
      self.series = series
      self.time = time
      self.durationMs = durationMs
      self.value = value
      self.persisted = persisted
    }
  }
  private struct Memory {
    var points: [String: [Point]] = [:]
    var apps: [(Double, JSONValue, Int)] = []
    var bytes = 0
  }
  private let memory = Locked(Memory())
  public init() {}
  public func append(_ points: [Point]) {
    memory.withLock { m in
      for point in points {
        guard m.points[point.series] != nil || m.points.count < 64 else { continue }
        var values = m.points[point.series] ?? []
        values.append(point)
        if values.count > 360 { values.removeFirst(values.count - 360) }
        values.removeAll { $0.time < point.time - 360 }
        m.points[point.series] = values
      }
      trim(&m)
    }
  }
  public func appendApps(at: Double, frame: JSONValue) {
    memory.withLock { m in
      let size = (try? frame.data().count) ?? 0
      m.apps.append((at, frame, size))
      if m.apps.count > 90 { m.apps.removeFirst() }
      m.apps.removeAll { $0.0 < at - 360 }
      trim(&m)
    }
  }
  private func trim(_ m: inout Memory) {
    // Includes conservative per-point/string overhead and actual app JSON bytes.
    m.bytes =
      m.points.values.reduce(0) { $0 + $1.count * 512 } + m.apps.reduce(0) { $0 + $1.2 * 2 + 256 }
    while m.bytes > 4 * 1_024 * 1_024 {
      if !m.apps.isEmpty {
        let frame = m.apps.removeFirst()
        m.bytes -= frame.2 * 2 + 256
      } else if let key = m.points.filter({ !$0.value.isEmpty }).min(by: {
        $0.value.first!.time < $1.value.first!.time
      })?.key {
        m.points[key]?.removeFirst()
        m.bytes -= 512
      } else {
        break
      }
    }
  }
  public func read(series: String, from: Double, to: Double, epoch: String) -> [Point] {
    memory.withLock {
      ($0.points[series] ?? []).filter { $0.epoch == epoch && $0.time > from && $0.time <= to }
    }
  }
  public func apps(from: Double, to: Double, epoch: String) -> [JSONValue] {
    memory.withLock {
      $0.apps.filter { $0.0 >= from && $0.0 <= to && $0.1["recordingEpoch"].string == epoch }.map(
        \.1)
    }
  }
  public func clear() { memory.withLock { $0 = Memory() } }
  public var allocatedBytes: Int { memory.withLock { $0.bytes } }
}
