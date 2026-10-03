import CMacBridge
import Foundation
import MonitorCore

public final class IOCollector {
  private var baselines = [CounterBaseline](repeating: CounterBaseline(), count: 4)
  private var interfaces: [String: (CounterBaseline, CounterBaseline)] = [:]
  public init() {}
  public func reset() {
    baselines = [CounterBaseline](repeating: CounterBaseline(), count: 4)
    interfaces.removeAll()
  }
  public func sample(intervalMs: Int) -> JSONValue {
    var nr: UInt64 = 0
    var nw: UInt64 = 0
    var dr: UInt64 = 0
    var dw: UInt64 = 0
    let status = cmm_io_counters(&nr, &nw, &dr, &dw)
    let now = HardwareProbe.monotonicNs
    let date = Date()
    var result: [String: JSONValue] = [:]
    for (index, item) in zip(
      [
        "networkReadBytesPerSecond", "networkWriteBytesPerSecond", "diskReadBytesPerSecond",
        "diskWriteBytesPerSecond",
      ], [nr, nw, dr, dw]
    ).enumerated() {
      let available = index < 2 ? status >= 0 : status == 0
      let value =
        available ? baselines[index].rate(identity: item.0, counter: item.1, monotonicNs: now) : nil
      if !available { baselines[index].reset() }
      let metric = Metric(
        value: value, unit: "bytesPerSecond",
        status: !available ? .unsupported : value == nil ? .warmingUp : .ok,
        source: index < 2 ? "getifaddrs physical en interfaces" : "IOBlockStorageDriver Statistics",
        sampledAt: date, intervalMs: intervalMs)
      result[item.0] = try? .from(metric)
    }
    var raw = [cmm_network_interface](repeating: cmm_network_interface(), count: 16)
    let count = raw.withUnsafeMutableBufferPointer {
      cmm_network_interfaces($0.baseAddress!, $0.count)
    }
    var rows: [JSONValue] = []
    var seen = Set<String>()
    if count > 0 {
      for var item in raw.prefix(Int(count)) {
        let name = withUnsafePointer(to: &item.name) { pointer in
          pointer.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        seen.insert(name)
        var pair = interfaces[name] ?? (CounterBaseline(), CounterBaseline())
        let read = pair.0.rate(identity: name, counter: item.received_bytes, monotonicNs: now)
        let write = pair.1.rate(identity: name, counter: item.sent_bytes, monotonicNs: now)
        interfaces[name] = pair
        rows.append(
          .object([
            "id": .string(name),
            "receivedBytesPerSecond":
              (try? .from(
                Metric(
                  value: read, unit: "bytesPerSecond", status: read == nil ? .warmingUp : .ok,
                  source: "getifaddrs " + name, sampledAt: date, intervalMs: intervalMs))) ?? .null,
            "sentBytesPerSecond":
              (try? .from(
                Metric(
                  value: write, unit: "bytesPerSecond", status: write == nil ? .warmingUp : .ok,
                  source: "getifaddrs " + name, sampledAt: date, intervalMs: intervalMs))) ?? .null,
          ]))
      }
    }
    interfaces = interfaces.filter { seen.contains($0.key) }
    result["networkInterfaces"] = .array(rows)
    return .object(result)
  }
}
