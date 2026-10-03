import Foundation
import Darwin
import MacCollectors
import MonitorCore
import ProbeSupport

struct Options {
    var duration = 1_800, warmup = 300
    var database = "artifacts/benchmarks/probe.sqlite"
    var certificate: String?, privateKey: String?
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count.isMultiple(of: 2) else { throw ProbeError.invalidArguments("Every flag requires a value") }
        for index in stride(from: 0, to: args.count, by: 2) {
            let value = args[index + 1]
            switch args[index] {
            case "--duration": guard let n = Int(value), (1...86_400).contains(n) else { throw ProbeError.invalidArguments("duration: 1...86400") }; duration = n
            case "--warmup": guard let n = Int(value), (0...3_600).contains(n) else { throw ProbeError.invalidArguments("warmup: 0...3600") }; warmup = n
            case "--database": database = value
            case "--certificate": certificate = value
            case "--private-key": privateKey = value
            default: throw ProbeError.invalidArguments("Unknown flag: \(args[index])")
            }
        }
    }
}

struct BenchmarkReport: Encodable {
    let schemaVersion = 1
    let generatedAt = Date()
    let architecture = HardwareProbe.architecture
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let effectiveUid = geteuid()
    let buildConfiguration: String
    let scenario = "feasibilityIdle"
    let durationSeconds: Double, warmupSeconds: Int
    let tlsInitialized: Bool, httpPort: Int, tlsPort: Int?
    let systemSamples: Int, processScans: Int
    let visibleProcessesMax: Int, readableProcessesMax: Int, deniedProcessesMax: Int
    let processScanDurationP95Ms: Double
    let cpuMeanCorePercent: Double, cpuP95CorePercent: Double
    let footprintP95Bytes: UInt64, footprintPeakBytes: UInt64, rssP95Bytes: UInt64
    let historyEnabled = true
    let historyCommits: Int, historyRows: Int, historyFileBytes: UInt64
    let samplingGaps: Int
    let sqliteVersion: String, sodiumVersion: String
    let gateStatus = "notValidated"
    let limitations: [String]
}

func p95<T: Comparable>(_ values: [T]) -> T {
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

do {
    umask(0o077)
    let options = try Options()
    let sodiumVersion = try CryptoProbe.version()
    let dbURL = URL(fileURLWithPath: options.database).standardizedFileURL
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // FULL synchronous minute transactions on one serial queue. No work is run on the HTTP event loop.
    let databaseQueue = DispatchQueue(label: "org.cloudmacmonitor.probe.database", qos: .utility)
    let db = try databaseQueue.sync { try ProbeDatabase(path: dbURL.path) }
    let server = ProbeHTTPServer()
    defer { try? server.close() }
    let httpPort = try server.start()
    let tlsPort = options.certificate == nil ? nil : try server.start(certificate: options.certificate, privateKey: options.privateKey)
    let ready: [String: Any] = ["httpPort": httpPort, "tlsPort": tlsPort.map { $0 as Any } ?? NSNull()]
    FileHandle.standardError.write(try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]))
    FileHandle.standardError.write(Data("\n".utf8))
    let collector = BasicSystemCollector()
    var segment = UUID()
    var baseline = CounterBaseline()
    var cpus: [Double] = [], footprints: [UInt64] = [], rss: [UInt64] = [], scans: [Double] = []
    var systemCount = 0, scanCount = 0, maxVisible = 0, maxReadable = 0, maxDenied = 0, commits = 0, gaps = 0
    var bucketCount = 0, covered = 0.0, weighted = 0.0, minimum = Double.infinity, maximum = -Double.infinity
    let initialOwn = try ProcessProbe.read(pid: getpid())
    _ = baseline.rate(identity: initialOwn.startTime, counter: initialOwn.cpuNs, monotonicNs: HardwareProbe.monotonicNs)
    let started = HardwareProbe.monotonicNs
    var lastTime = started
    var previousWall = Date().timeIntervalSince1970
    var bucketMinute = Int64(previousWall / 60)
    var measurementStarted: UInt64?
    var measuredCpuStart: UInt64?
    var scanDeadline = started + 1_000_000_000
    let ticks = options.warmup + options.duration
    for tick in 0..<ticks {
        if tick == options.warmup {
            measuredCpuStart = try ProcessProbe.read(pid: getpid()).cpuNs
            measurementStarted = HardwareProbe.monotonicNs
        }
        let deadline = started + UInt64(tick + 1) * 1_000_000_000
        let now = HardwareProbe.monotonicNs
        if now < deadline { Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000) }
        let sample = collector.sample()
        let elapsed = Double(sample.monotonicNs - lastTime) / 1_000_000_000
        let wall = sample.sampledAt.timeIntervalSince1970
        let jumped = elapsed > 3 || abs((wall - previousWall) - elapsed) > 2
        if jumped { gaps += 1; collector.reset(); baseline.reset() }
        let minute = Int64(wall / 60)
        if minute != bucketMinute || jumped {
            if bucketCount > 0 {
                try databaseQueue.sync { try db.commit(segment: segment, minute: bucketMinute, count: bucketCount,
                                                      coveredMs: covered, weightedSum: weighted, minimum: minimum, maximum: maximum) }
                commits += 1
            }
            bucketMinute = minute; bucketCount = 0; covered = 0; weighted = 0; minimum = .infinity; maximum = -.infinity
            if jumped { segment = UUID() }
        }
        if let cpu = sample.cpu.value, !jumped {
            bucketCount += 1; covered += elapsed * 1_000; weighted += cpu * elapsed * 1_000
            minimum = min(minimum, cpu); maximum = max(maximum, cpu)
        }
        lastTime = sample.monotonicNs; previousWall = wall
        systemCount += 1
        if sample.monotonicNs >= scanDeadline {
            let scan = try ProcessProbe.scan()
            scanCount += 1
            maxVisible = max(maxVisible, scan.coverage.attempted); maxReadable = max(maxReadable, scan.coverage.readable)
            maxDenied = max(maxDenied, scan.coverage.denied)
            if tick >= options.warmup { scans.append(scan.coverage.durationMs) }
            repeat { scanDeadline += 4_000_000_000 } while scanDeadline <= sample.monotonicNs
        }
        if tick.isMultiple(of: 300), tick > 0 { try databaseQueue.sync { try db.checkpoint() } }
        let own = try ProcessProbe.read(pid: getpid())
        let rate = baseline.rate(identity: own.startTime, counter: own.cpuNs, monotonicNs: HardwareProbe.monotonicNs)
        if tick >= options.warmup {
            if let rate { cpus.append(rate / 10_000_000) }
            footprints.append(own.footprintBytes); rss.append(own.rssBytes)
        }
    }
    if bucketCount > 0 {
        try databaseQueue.sync { try db.commit(segment: segment, minute: bucketMinute, count: bucketCount,
                                              coveredMs: covered, weightedSum: weighted, minimum: minimum, maximum: maximum) }
        commits += 1
    }
    let historyRows = try databaseQueue.sync { try db.rowCount() }
    let fileBytes = [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"].reduce(UInt64(0)) { sum, path in
        sum + (((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0)
    }
    let measuredCpuEnd = try ProcessProbe.read(pid: getpid()).cpuNs
    let duration = Double(HardwareProbe.monotonicNs - (measurementStarted ?? started)) / 1_000_000_000
    #if DEBUG
    let configuration = "debug"
    #else
    let configuration = "release"
    #endif
    let report = BenchmarkReport(buildConfiguration: configuration, durationSeconds: duration, warmupSeconds: options.warmup,
                                  tlsInitialized: tlsPort != nil, httpPort: httpPort, tlsPort: tlsPort,
                                  systemSamples: systemCount, processScans: scanCount, visibleProcessesMax: maxVisible,
                                  readableProcessesMax: maxReadable, deniedProcessesMax: maxDenied,
                                  processScanDurationP95Ms: scans.isEmpty ? 0 : p95(scans),
                                  cpuMeanCorePercent: duration > 0 ? Double(measuredCpuEnd - (measuredCpuStart ?? measuredCpuEnd)) / (duration * 10_000_000) : 0,
                                  cpuP95CorePercent: cpus.isEmpty ? 0 : p95(cpus),
                                  footprintP95Bytes: p95(footprints), footprintPeakBytes: footprints.max()!, rssP95Bytes: p95(rss),
                                  historyCommits: commits, historyRows: historyRows, historyFileBytes: fileBytes, samplingGaps: gaps,
                                  sqliteVersion: ProbeDatabase.version, sodiumVersion: sodiumVersion,
                                  limitations: ["Feasibility baseline only: not the complete 64-series/app-summary history workload",
                                                "Does not generate client traffic; TLS initialization alone is not a handshake/client benchmark",
                                                "Actual visible process count reported; no synthetic 500-process claim",
                                                "Apple Silicon, system-domain/no-desktop, 3 repeated 30-minute runs still required",
                                                "Short runs and runs without the required 300s warmup are smoke tests, not stable budget results"])
    FileHandle.standardOutput.write(try JSONReport.encode(report)); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Benchmark: \(error)\n".utf8)); exit(1)
}
