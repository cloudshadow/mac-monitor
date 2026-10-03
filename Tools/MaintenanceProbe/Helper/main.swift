import Foundation
import Darwin
import MaintenancePrototype

struct ToolError: Error, CustomStringConvertible {
    let description: String
}

func checkProtectedPath(_ path: String, regular: Bool) throws {
    var current = URL(fileURLWithPath: path).standardizedFileURL
    var leaf = true
    while current.path != "/" {
        var info = stat()
        guard lstat(current.path, &info) == 0, info.st_uid == 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_mode & S_IFMT != S_IFLNK else {
            throw ToolError(description: "Unsafe ownership, permissions or symlink: \(current.path)")
        }
        if leaf && regular && info.st_mode & S_IFMT != S_IFREG {
            throw ToolError(description: "Not a regular file: \(path)")
        }
        leaf = false
        current.deleteLastPathComponent()
    }
}

@discardableResult
func launchctl(_ args: [String], allowFailure: Bool = false) throws -> (Int32, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    if process.terminationStatus != 0 && !allowFailure {
        throw ToolError(description: "launchctl \(args.first ?? "") failed (\(process.terminationStatus)): \(output)")
    }
    return (process.terminationStatus, output)
}

func disabled() throws -> Bool {
    let (_, output) = try launchctl(["print-disabled", "system"])
    // Unknown output must fail closed, not silently enable a task.
    return try PrototypeStateParser.isDisabled(output)
}

func loaded() throws -> Bool {
    try launchctl(["print", PrototypePaths.job], allowFailure: true).0 == 0
}

do {
    guard CommandLine.arguments.count == 2, let action = PrototypeAction(rawValue: CommandLine.arguments[1]) else {
        throw ToolError(description: "Allowed actions: status enable start disable stop uninstall")
    }
    guard geteuid() == 0 else { throw ToolError(description: "Administrator authorization required") }
    try checkProtectedPath(PrototypePaths.helper, regular: true)
    try checkProtectedPath(PrototypePaths.root, regular: false)
    let lockPath = PrototypePaths.root + "/maintenance.lock"
    let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw ToolError(description: "Cannot open transaction lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ToolError(description: "Another maintenance operation is running") }
    var lockStat = stat()
    guard fstat(lock, &lockStat) == 0, lockStat.st_uid == 0, lockStat.st_nlink == 1,
          lockStat.st_mode & S_IFMT == S_IFREG else { throw ToolError(description: "Unsafe lock file") }
    // Root-protected prototype journal reports partial failure; it is not production recovery logic.
    let journal = URL(fileURLWithPath: PrototypePaths.root + "/operation.json")
    let beforeDisabled = try disabled(), beforeLoaded = try loaded()
    let initial: [String: Any] = ["action": action.rawValue, "phase": "started", "disabled": beforeDisabled, "loaded": beforeLoaded]
    if action != .status { try JSONSerialization.data(withJSONObject: initial, options: [.sortedKeys]).write(to: journal, options: .atomic) }
    switch action {
    case .status: break
    case .disable:
        try launchctl(["disable", PrototypePaths.job]) // Deliberately does not bootout a running job.
    case .stop, .uninstall:
        try launchctl(["disable", PrototypePaths.job])
        guard try disabled() else { throw ToolError(description: "Disable verification failed; no bootout attempted") }
        if try loaded() { try launchctl(["bootout", PrototypePaths.job]) }
        if action == .uninstall && FileManager.default.fileExists(atPath: PrototypePaths.plist) {
            try checkProtectedPath(PrototypePaths.plist, regular: true)
            try FileManager.default.removeItem(atPath: PrototypePaths.plist)
        }
    case .start, .enable:
        try checkProtectedPath(PrototypePaths.plist, regular: true)
        if action == .start && beforeDisabled { throw ToolError(description: "serviceDisabled: use explicit enable") }
        if action == .enable { try launchctl(["enable", PrototypePaths.job]) }
        if !(try loaded()) { try launchctl(["bootstrap", "system", PrototypePaths.plist]) }
        let (_, state) = try launchctl(["print", PrototypePaths.job])
        if !state.contains("state = running") { try launchctl(["kickstart", PrototypePaths.job]) }
    }
    let (_, observed) = try launchctl(["print", PrototypePaths.job], allowFailure: true)
    let final: [String: Any] = ["action": action.rawValue, "phase": "completed", "disabled": try disabled(), "loaded": try loaded(), "observed": observed,
                               "limitation": "G4 prototype only; production prepareStop/owner migration/update recovery are not implemented"]
    let data = try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys])
    if action != .status { try data.write(to: journal, options: .atomic) }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("MaintenanceProbeHelper: \(error)\nInspect the protected operation journal and actual launchctl state; partial mutations may have succeeded.\n".utf8))
    exit(1)
}
