import Foundation
import Darwin
import MacCollectors
import MonitorCore
import ProbeSupport

struct CapabilityReport: Encodable {
    let schemaVersion = 1
    let generatedAt = Date()
    let architecture = HardwareProbe.architecture
    let modelIdentifier = HardwareProbe.string("hw.model") ?? "unknown"
    let chipName = HardwareProbe.string("machdep.cpu.brand_string") ?? "unknown"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let effectiveUid = geteuid()
    let logicalCpuCount = ProcessInfo.processInfo.activeProcessorCount
    let launchContext: String
    let system: BasicSystemSample
    let processes: ScanCoverage
    let sameUidReadable: Int
    let otherUidReadable: Int
    let sensors: SensorProbeReport
    let sqliteVersion: String
    let sodiumVersion: String
    let verified = false
    let notes: [String]
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.isEmpty || args == ["--launch-context", "system"] || args == ["--launch-context", "interactive"] else {
        throw ProbeError.invalidArguments("Usage: CapabilityProbe [--launch-context system|interactive]")
    }
    let collector = BasicSystemCollector()
    _ = collector.sample()
    Thread.sleep(forTimeInterval: 1)
    let system = collector.sample()
    let scan = try ProcessProbe.scan()
    let report = CapabilityReport(launchContext: args.last ?? "unspecified",
                                  system: system, processes: scan.coverage,
                                  sameUidReadable: scan.rows.filter { $0.uid == geteuid() }.count,
                                  otherUidReadable: scan.rows.filter { $0.uid != geteuid() }.count,
                                  sensors: .read(), sqliteVersion: ProbeDatabase.version,
                                  sodiumVersion: try CryptoProbe.version(),
                                  notes: ["launchContext is operator-declared; verify launchctl/system and no desktop session separately",
                                          "SMC/HID/GPU interface presence does not verify sensor mappings or metric accuracy",
                                          "No process names, command lines, paths or hardware serial numbers are included"])
    FileHandle.standardOutput.write(try JSONReport.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("CapabilityProbe: \(error)\n".utf8)); exit(1)
}
