import CMacBridge
import Darwin
import Foundation
import MonitorCore

/// Only read-only SMC commands are exposed by the bridge. Unknown formats are rejected.
public enum SensorCollector {
  private static let readableSMCKeys = Locked<[String]?>(nil)
  private static let diskCache = Locked((date: Date.distantPast, sensors: [JSONValue]()))
  public static func temperatures(intervalMs: Int) -> JSONValue {
    let date = Date()
    var readings: [JSONValue] = []
    var denied = false
    // Open one SMC connection per batch; unsupported keys are discovered only once.
    let definitions = readableSMCKeys.withLock { cached in
      cached.map { keys in SensorCatalog.definitions.filter { keys.contains($0.key) } } ?? SensorCatalog.definitions
    }
    var smc = definitions.map { definition in
      var reading = cmm_smc_reading()
      withUnsafeMutablePointer(to: &reading.key) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 5) { buffer in
          for (index, byte) in definition.key.utf8.enumerated() { buffer[index] = CChar(bitPattern: byte) }
        }
      }
      return reading
    }
    let batchStatus = smc.isEmpty ? 0 : smc.withUnsafeMutableBufferPointer { cmm_smc_temperatures($0.baseAddress!, $0.count) }
    denied = batchStatus == EACCES
    if batchStatus != EACCES {
      readableSMCKeys.withLock { cache in
        if cache == nil { cache = zip(definitions, smc).filter { $0.1.status == 0 }.map { $0.0.key } }
      }
    }
    for (definition, reading) in zip(definitions, smc) where reading.status == 0 {
      var fields: [String: JSONValue] = [
        "id": .string("smc:" + definition.key), "label": .string(definition.label),
        "category": .string(definition.category), "mappingVerified": .bool(false),
        "mappingReference": .string(SensorCatalog.reference),
        "metric": (try? .from(Metric(value: reading.celsius, unit: "celsius", status: .ok,
          source: "AppleSMC " + definition.key, sampledAt: date, intervalMs: intervalMs))) ?? .null,
      ]
      if let family = definition.family { fields["family"] = .string(family) }
      readings.append(.object(fields))
    }
    var hid = [cmm_hid_temperature](repeating: cmm_hid_temperature(), count: 64)
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
    readings += diskTemperatures()
    let unavailable = Metric(
      value: nil, unit: "celsius", status: denied ? .permissionDenied : .unsupported,
      source: "AppleSMC", sampledAt: date, intervalMs: intervalMs,
      reason: readings.isEmpty ? "noReadableSensor" : "sensorMappingNotVerified")
    return .object(["metric": (try? .from(unavailable)) ?? .null, "sensors": .array(readings)])
  }
  private static func diskTemperatures() -> [JSONValue] {
    diskCache.withLock { cache in
      if Date().timeIntervalSince(cache.date) < 60 { return cache.sensors }
      let date = Date()
      var disks = [cmm_disk_temperature](repeating: cmm_disk_temperature(), count: 32)
      let count = disks.withUnsafeMutableBufferPointer { cmm_disk_temperatures($0.baseAddress!, $0.count) }
      cache.sensors = disks.prefix(max(0, Int(count))).map { disk in
        var disk = disk
        let name = withUnsafePointer(to: &disk.name) { $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } }
        let id = withUnsafePointer(to: &disk.id) { $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } }
        let status: MetricStatus = disk.status == 0 ? .ok : disk.status == EACCES ? .permissionDenied : disk.status == ENOTSUP ? .unsupported : .error
        let metric = Metric(value: disk.status == 0 ? disk.celsius : nil, unit: "celsius", status: status,
          source: "Drive SMART", sampledAt: date, intervalMs: 60000,
          reason: disk.status == 0 ? nil : "driveTemperatureUnavailable")
        return .object(["id": .string("disk:" + id), "label": .string(name), "category": .string("storage"),
          "external": .bool(disk.external != 0), "mappingVerified": .bool(true),
          "metric": (try? .from(metric)) ?? .null])
      }
      cache.date = date
      return cache.sensors
    }
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
