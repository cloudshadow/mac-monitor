import CMacBridge
import Darwin
import Foundation
import MonitorCore

/// Only read-only SMC commands are exposed by the bridge. Unknown formats are rejected.
public enum SensorCollector {
  public static func temperatures(intervalMs: Int) -> JSONValue {
    let date = Date()
    var readings: [JSONValue] = []
    var denied = false
    // Fixed, bounded discovery list. IDs are preserved; no model-specific CPU/GPU attribution is guessed.
    for key in ["TC0D", "TC0P", "Tp09", "Tp0T", "Tp0P", "Tp1P", "Tg0P", "TG0D"] {
      var value = 0.0
      let status = key.withCString { cmm_smc_temperature($0, &value) }
      denied = denied || status == EACCES
      if status == 0 {
        readings.append(
          .object([
            "id": .string("smc:" + key), "label": .string(key), "mappingVerified": .bool(false),
            "metric":
              (try? .from(
                Metric(
                  value: value, unit: "celsius", status: .ok, source: "AppleSMC " + key,
                  sampledAt: date, intervalMs: intervalMs))) ?? .null,
          ]))
      }
    }
    var hid = [cmm_hid_temperature](repeating: cmm_hid_temperature(), count: 8)
    let count = hid.withUnsafeMutableBufferPointer {
      cmm_hid_temperatures($0.baseAddress!, $0.count)
    }
    if count > 0 {
      for var reading in hid.prefix(Int(count)) {
        let name = withUnsafePointer(to: &reading.name) { pointer in
          pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
        readings.append(
          .object([
            "id": .string("hid:" + name), "label": .string(name), "mappingVerified": .bool(false),
            "metric":
              (try? .from(
                Metric(
                  value: reading.celsius, unit: "celsius", status: .ok, source: "IOHID " + name,
                  sampledAt: date, intervalMs: intervalMs))) ?? .null,
          ]))
      }
    }
    let unavailable = Metric(
      value: nil, unit: "celsius", status: denied ? .permissionDenied : .unsupported,
      source: "AppleSMC", sampledAt: date, intervalMs: intervalMs,
      reason: readings.isEmpty ? "noReadableSensor" : "sensorMappingNotVerified")
    return .object(["metric": (try? .from(unavailable)) ?? .null, "sensors": .array(readings)])
  }
  public static func gpu(intervalMs: Int) -> Metric {
    var value = 0.0
    let status = cmm_gpu_percent(&value)
    return Metric(
      value: status == 0 ? value : nil, unit: "percent",
      status: status == 0 ? .ok : status == EACCES ? .permissionDenied : .unsupported,
      source: "IOAccelerator Device Utilization %", sampledAt: Date(), intervalMs: intervalMs,
      reason: status == 0 ? nil : "driverStatisticsUnavailable")
  }
}
