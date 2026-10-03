import CMacBridge
import Foundation
import MonitorCore

/// Owned by the shared collection queue; paths never leave this collector.
public final class ApplicationCollector {
  private struct Previous {
    let sample: RawProcessSample
    let time: UInt64
  }
  private struct Metadata {
    let id: String, name: String, attribution: String, nameTruncated: Bool
    init(id: String, name: String, attribution: String) {
      self.id = id
      self.name = ApplicationCollector.bounded(name)
      self.attribution = attribution
      self.nameTruncated = name.utf8.count > 256
    }
  }
  private var previous: [String: Previous] = [:]
  private var metadata: [String: Metadata] = [:]
  public let bootId: String
  private let identify: (String) -> String
  private var sequence: UInt64 = 0
  public init(bootId: String = UUID().uuidString, identify: @escaping (String) -> String) {
    self.bootId = bootId
    self.identify = identify
  }
  public func reset() { previous.removeAll() }
  public func sample(intervalMs: Int) throws -> JSONValue {
    let scan = try ProcessProbe.scan()
    let now = HardwareProbe.monotonicNs
    let date = Date()
    sequence += 1
    var next: [String: Previous] = [:]
    var apps: [String: [String: JSONValue]] = [:]
    var members: [String: [JSONValue]] = [:]
    for p in scan.rows {
      let key = "\(bootId):\(p.pid):\(p.startTime)"
      let old = previous[key]
      next[key] = Previous(sample: p, time: now)
      var pathBytes = [CChar](repeating: 0, count: 4096)
      let pathLength = cmm_process_path(p.pid, &pathBytes, UInt32(pathBytes.count))
      // Validate the identity again after metadata lookup, which can race process exit/reuse.
      guard let check = try? ProcessProbe.read(pid: p.pid), check.startTime == p.startTime else {
        continue
      }
      let path =
        pathLength > 0 ? pathBytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : ""
      let cacheKey = path.isEmpty ? key : path
      let info: Metadata
      if let cached = metadata[cacheKey] {
        info = cached
      } else {
        let components = path.split(separator: "/")
        let appIndex = components.firstIndex { $0.hasSuffix(".app") }
        if let index = appIndex {
          let root = "/" + components.prefix(index + 1).joined(separator: "/")
          let bundle = Bundle(path: root)
          let bundleId = bundle?.bundleIdentifier ?? ""
          let name =
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle?
            .object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? String(components[index].dropLast(4))
          info = Metadata(
            id: identify("app:\(bundleId):\(root)"), name: name,
            attribution: bundleId.isEmpty ? "unattributed" : "verifiedBundle")
        } else {
          info = Metadata(
            id: identify("process:\(cacheKey)"),
            name: (URL(fileURLWithPath: path).lastPathComponent.isEmpty
              ? "PID \(p.pid)" : URL(fileURLWithPath: path).lastPathComponent),
            attribution: "unattributed")
        }
        if metadata.count >= 4096 { metadata.removeAll(keepingCapacity: true) }
        metadata[cacheKey] = info
      }
      let elapsed = old.map { Double(now - $0.time) / 1e9 } ?? 0
      func rate(_ value: UInt64, _ prior: UInt64?) -> Double? {
        guard let prior, elapsed > 0, elapsed <= 30, value >= prior else { return nil }
        return Double(value - prior) / elapsed
      }
      let cpu = rate(p.cpuNs, old?.sample.cpuNs).map { $0 / 1e7 }
      let read = rate(p.diskReadBytes, old?.sample.diskReadBytes)
      let write = rate(p.diskWriteBytes, old?.sample.diskWriteBytes)
      let appId = info.attribution == "unattributed" ? key : info.id
      let row: JSONValue = .object([
        "uid": .number(Double(p.uid)), "appId": .string(appId), "sampledAt": .date(date),
        "status": .string(cpu == nil ? "warmingUp" : "ok"),
        "processKey": .string(key), "pid": .number(Double(p.pid)),
        "startTime": .string(p.startTime), "name": .string(info.name),
        "cpuPercentCore": cpu.map(JSONValue.number) ?? .null,
        "cpuPercentMachine": cpu.map {
          .number($0 / Double(ProcessInfo.processInfo.activeProcessorCount))
        } ?? .null, "physicalFootprintBytes": .number(Double(p.footprintBytes)),
        "rssBytes": .number(Double(p.rssBytes)),
        "diskReadBytesPerSecond": read.map(JSONValue.number) ?? .null,
        "diskWriteBytesPerSecond": write.map(JSONValue.number) ?? .null,
      ])
      var app =
        apps[appId] ?? [
          "id": .string(appId), "name": .string(info.name), "displayName": .string(info.name),
          "nameTruncated": .bool(info.nameTruncated),
          "confidence": .number(info.attribution == "unattributed" ? 0 : 0.8),
          "attribution": .string(info.attribution),
          "physicalFootprintBytes": .number(0), "rssBytes": .number(0),
        ]
      members[appId, default: []].append(row)
      for field in [
        "cpuPercentCore", "cpuPercentMachine", "physicalFootprintBytes", "rssBytes",
        "diskReadBytesPerSecond", "diskWriteBytesPerSecond",
      ] {
        if let value = row[field].number {
          app[field] = .number((app[field]?.number ?? 0) + value)
        } else if app[field] == nil {
          app[field] = .null
        }
      }
      apps[appId] = app
    }
    previous = next
    let rows = apps.values.map { value -> JSONValue in
      var v = value
      v["members"] = .array(members[v["id"]?.string ?? ""] ?? [])
      v["processCount"] = .number(Double(v["members"]?.array.count ?? 0))
      v["memberCount"] = v["processCount"]
      return .object(v)
    }
    return .object([
      "bootId": .string(bootId), "scanSequence": .string(String(sequence)),
      "sampledAt": .date(date), "intervalMs": .number(Double(intervalMs)),
      "coverage": try .from(scan.coverage), "rows": .array(rows),
    ])
  }
  private static func bounded(_ value: String) -> String {
    var result = ""
    for char in value {
      if result.utf8.count + String(char).utf8.count > 256 { break }
      if !char.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
        result.append(char)
      }
    }
    return result
  }
}
