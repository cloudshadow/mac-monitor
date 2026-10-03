import Foundation

public enum JSONValue: Codable, Sendable, Equatable, Hashable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self), n.isFinite {
      self = .number(n)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let o): try c.encode(o)
    case .array(let a): try c.encode(a)
    case .string(let s): try c.encode(s)
    case .number(let n): if n.isFinite { try c.encode(n) } else { try c.encodeNil() }
    case .bool(let b): try c.encode(b)
    case .null: try c.encodeNil()
    }
  }
  public subscript(_ key: String) -> JSONValue {
    if case .object(let o) = self { return o[key] ?? .null }
    return .null
  }
  public var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }
  public var number: Double? {
    if case .number(let n) = self { return n }
    return nil
  }
  public var bool: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }
  public var array: [JSONValue] {
    if case .array(let a) = self { return a }
    return []
  }
  public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(Self.self, from: wireEncoder().encode(value))
  }
  public static func wireEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys]
    return e
  }
  public func data() throws -> Data { try Self.wireEncoder().encode(self) }
  public static func date(_ d: Date = Date()) -> Self {
    .string(ISO8601DateFormatter().string(from: d))
  }
}

public struct APIError: Error, Sendable {
  public let status: Int, code: String
  public let details: [String: JSONValue]
  public init(_ status: Int, _ code: String, _ details: [String: JSONValue] = [:]) {
    self.status = status
    self.code = code
    self.details = details
  }
  public var json: JSONValue {
    var d = details
    d["code"] = .string(code)
    d["message"] = .string(code)
    return .object(["error": .object(d)])
  }
}

public final class Locked<Value>: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var value: Value
  public init(_ value: Value) { self.value = value }
  public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
