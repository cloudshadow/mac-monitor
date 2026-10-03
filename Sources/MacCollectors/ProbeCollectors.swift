import CMacBridge
import Darwin
import Foundation
import MonitorCore

public struct BasicSystemSample: Codable, Sendable {
  public let sampledAt: Date
  public let monotonicNs: UInt64
  public let cpu: Metric
  public let physicalMemoryBytes: UInt64?
  public let freeBytes: UInt64?, speculativeBytes: UInt64?, activeBytes: UInt64?
  public let inactiveBytes: UInt64?, wiredBytes: UInt64?, compressorBytes: UInt64?
  public let nonIdlePercent: Metric
  public let swapUsedBytes: Metric
  public let memoryPressure: String
  public let thermalState: Int
}

/// Serially owned by the probe. This is deliberately independent of AppKit/login sessions.
public final class BasicSystemCollector {
  private var cpu = CPUBaseline()
  public init() {}
  public func reset() { cpu.reset() }
  public func sample(intervalMs: Int = 1_000) -> BasicSystemSample {
    var raw = cmm_system_sample()
    _ = cmm_read_system(&raw)
    let now = Date()
    let monotonic = cmm_continuous_ns()
    let percent: Double?
    if raw.cpu_error == 0 {
      percent = cpu.percent(
        .init(
          user: raw.user_ticks, system: raw.system_ticks, idle: raw.idle_ticks, nice: raw.nice_ticks
        ))
    } else {
      cpu.reset()
      percent = nil
    }
    let nonIdle =
      raw.memory_error == 0 && raw.total_bytes > 0
      ? 100
        * max(0, Double(raw.total_bytes) - Double(raw.free_bytes) - Double(raw.speculative_bytes))
        / Double(raw.total_bytes) : nil
    return .init(
      sampledAt: now, monotonicNs: monotonic,
      cpu: Metric(
        value: percent, unit: "percentMachine",
        status: raw.cpu_error != 0 ? .error : percent == nil ? .warmingUp : .ok,
        source: "host_statistics", sampledAt: now, intervalMs: intervalMs),
      physicalMemoryBytes: raw.total_bytes > 0 ? raw.total_bytes : nil,
      freeBytes: raw.memory_error == 0 ? raw.free_bytes : nil,
      speculativeBytes: raw.memory_error == 0 ? raw.speculative_bytes : nil,
      activeBytes: raw.memory_error == 0 ? raw.active_bytes : nil,
      inactiveBytes: raw.memory_error == 0 ? raw.inactive_bytes : nil,
      wiredBytes: raw.memory_error == 0 ? raw.wired_bytes : nil,
      compressorBytes: raw.memory_error == 0 ? raw.compressor_bytes : nil,
      nonIdlePercent: Metric(
        value: nonIdle, unit: "percent", status: raw.memory_error == 0 ? .ok : .error,
        source: "host_statistics64+hw.memsize", sampledAt: now, intervalMs: intervalMs),
      swapUsedBytes: Metric(
        value: raw.swap_error == 0 ? Double(raw.swap_used_bytes) : nil, unit: "bytes",
        status: raw.swap_error == 0 ? .ok : .error,
        source: "vm.swapusage", sampledAt: now, intervalMs: intervalMs),
      memoryPressure: [1: "normal", 2: "warning", 4: "critical"][Int(cmm_memory_pressure())]
        ?? "unknown", thermalState: ProcessInfo.processInfo.thermalState.rawValue)
  }
}

public struct RawProcessSample: Codable, Sendable {
  public let pid: Int32, uid: UInt32
  public let startTime: String
  public let cpuNs: UInt64, footprintBytes: UInt64, rssBytes: UInt64
  public let diskReadBytes: UInt64, diskWriteBytes: UInt64
  public init(_ raw: cmm_process_sample) {
    pid = raw.pid
    uid = raw.uid
    startTime = String(raw.start_seconds * 1_000_000 + raw.start_microseconds)
    cpuNs = raw.user_ns + raw.system_ns
    footprintBytes = raw.footprint_bytes
    rssBytes = raw.resident_bytes
    diskReadBytes = raw.disk_read_bytes
    diskWriteBytes = raw.disk_write_bytes
  }
}

public struct ScanCoverage: Codable, Sendable {
  public var attempted = 0, readable = 0, denied = 0, exited = 0, errors = 0
  public var identityLimitReached = false
  public var durationMs: Double = 0
}

public struct ProcessScan: Sendable {
  public let rows: [RawProcessSample]
  public let coverage: ScanCoverage
}

public enum ProcessProbe {
  public static func read(pid: Int32) throws -> RawProcessSample {
    var raw = cmm_process_sample()
    let code = cmm_read_process(pid, &raw)
    guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    return RawProcessSample(raw)
  }
  public static func scan() throws -> ProcessScan {
    let start = cmm_continuous_ns()
    // One spare slot detects overflow without allocating an unbounded PID list.
    var ids = [Int32](repeating: 0, count: 4_097)
    let count = ids.withUnsafeMutableBufferPointer { cmm_list_pids($0.baseAddress!, $0.count) }
    guard count >= 0 else { throw POSIXError(.EIO) }
    var coverage = ScanCoverage()
    coverage.identityLimitReached = count >= ids.count
    var rows: [RawProcessSample] = []
    rows.reserveCapacity(min(Int(count), 4_096))
    for pid in ids.prefix(min(Int(count), 4_096)) where pid > 0 {
      coverage.attempted += 1
      do {
        rows.append(try read(pid: pid))
        coverage.readable += 1
      } catch let error as POSIXError {
        if error.code == .EPERM || error.code == .EACCES {
          coverage.denied += 1
        } else if error.code == .ESRCH || error.code == .ENOENT {
          coverage.exited += 1
        } else {
          coverage.errors += 1
        }
      } catch { coverage.errors += 1 }
    }
    coverage.durationMs = Double(cmm_continuous_ns() - start) / 1_000_000
    return ProcessScan(rows: rows, coverage: coverage)
  }
}

public struct SensorProbeReport: Codable, Sendable {
  public let smcOpenStatus: Int
  public let hidServiceCount: Int
  public let gpuServiceCount: Int
  public let temperature: Metric
  public let gpu: Metric
  public let durationMs: Double
  public static func read() -> Self {
    let start = cmm_continuous_ns()
    let now = Date()
    let smc = cmm_smc_open_status()
    let hid = cmm_registry_service_count("AppleHIDEventService")
    let gpu = cmm_registry_service_count("IOAccelerator")
    // Registry presence or an open SMC handle is NOT a verified temperature/GPU measurement.
    return .init(
      smcOpenStatus: Int(smc), hidServiceCount: Int(hid), gpuServiceCount: Int(gpu),
      temperature: Metric(
        value: nil, unit: "celsius", status: .unsupported, source: "AppleSMC/IOHID probe",
        sampledAt: now,
        intervalMs: 10_000, reason: "sensorMappingNotVerified"),
      gpu: Metric(
        value: nil, unit: "percent", status: .unsupported, source: "IORegistry probe",
        sampledAt: now,
        intervalMs: 5_000, reason: "driverStatisticsNotVerified"),
      durationMs: Double(cmm_continuous_ns() - start) / 1_000_000)
  }
}

public enum HardwareProbe {
  public static func string(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 4_096 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }
  public static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }
  public static var monotonicNs: UInt64 { cmm_continuous_ns() }
}
