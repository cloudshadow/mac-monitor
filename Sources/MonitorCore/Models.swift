import Foundation

public enum MetricStatus: String, Codable, Sendable {
  case warmingUp, ok, unsupported, permissionDenied, error, stale
}

/// Missing values are never represented by zero. All JSON numbers must be finite.
public struct Metric: Codable, Sendable, Equatable {
  public let value: Double?
  public let unit: String
  public let status: MetricStatus
  public let source: String
  public let sampledAt: Date
  public let intervalMs: Int
  public let reason: String?

  public init(
    value: Double?, unit: String, status: MetricStatus, source: String,
    sampledAt: Date, intervalMs: Int, reason: String? = nil
  ) {
    let permitsValue = status == .ok || status == .stale
    let finiteValue = value.flatMap { $0.isFinite ? $0 : nil }
    self.value = permitsValue ? finiteValue : nil
    self.status = permitsValue && finiteValue == nil ? .error : status
    self.unit = unit
    self.source = source
    self.sampledAt = sampledAt
    self.intervalMs = intervalMs
    self.reason = permitsValue && finiteValue == nil ? "nonFiniteOrMissingValue" : reason
  }

  // Decode through the invariant-preserving initializer as well.
  private enum CodingKeys: String, CodingKey {
    case value, unit, status, source, sampledAt, intervalMs, reason
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      value: try c.decodeIfPresent(Double.self, forKey: .value),
      unit: try c.decode(String.self, forKey: .unit),
      status: try c.decode(MetricStatus.self, forKey: .status),
      source: try c.decode(String.self, forKey: .source),
      sampledAt: try c.decode(Date.self, forKey: .sampledAt),
      intervalMs: try c.decode(Int.self, forKey: .intervalMs),
      reason: try c.decodeIfPresent(String.self, forKey: .reason))
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
    try c.encode(unit, forKey: .unit)
    try c.encode(status, forKey: .status)
    try c.encode(source, forKey: .source)
    try c.encode(sampledAt, forKey: .sampledAt)
    try c.encode(intervalMs, forKey: .intervalMs)
    try c.encodeIfPresent(reason, forKey: .reason)
  }
}

public struct ProcessIdentity: Hashable, Codable, Sendable {
  public let bootId: UUID
  public let pid: Int32
  public let startTime: String
  public var processKey: String { "\(bootId.uuidString):\(pid):\(startTime)" }
  public init(bootId: UUID, pid: Int32, startTime: String) {
    self.bootId = bootId
    self.pid = pid
    self.startTime = startTime
  }
}

public struct CounterBaseline: Sendable {
  private var previous: (identity: String, counter: UInt64, time: UInt64)?
  public init() {}
  public mutating func reset() { previous = nil }
  public mutating func rate(identity: String, counter: UInt64, monotonicNs: UInt64) -> Double? {
    defer { previous = (identity, counter, monotonicNs) }
    guard let old = previous, old.identity == identity,
      counter >= old.counter, monotonicNs > old.time
    else { return nil }
    return Double(counter - old.counter) * 1_000_000_000 / Double(monotonicNs - old.time)
  }
}

public struct CPUTicks: Sendable {
  public let user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
  public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
    self.user = user
    self.system = system
    self.idle = idle
    self.nice = nice
  }
}

public struct CPUBaseline: Sendable {
  private var previous: CPUTicks?
  public init() {}
  public mutating func reset() { previous = nil }
  public mutating func percent(_ next: CPUTicks) -> Double? {
    defer { previous = next }
    guard let old = previous,
      next.user >= old.user, next.system >= old.system,
      next.idle >= old.idle, next.nice >= old.nice
    else { return nil }
    let busy =
      Double(next.user - old.user) + Double(next.system - old.system) + Double(next.nice - old.nice)
    let total = busy + Double(next.idle - old.idle)
    return total > 0 ? 100 * busy / total : nil
  }
}

public enum JSONReport {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
}
