import Foundation

public enum PrototypeAction: String, CaseIterable, Sendable {
    case status, enable, start, disable, stop, uninstall
    public var arguments: [String] { [rawValue] }
    public var appleScript: String {
        // Only compiled enum values and one fixed, root-owned executable enter the shell.
        "do shell script \"'\(PrototypePaths.helper)' '\(rawValue)'\" with administrator privileges"
    }
}

public enum PrototypePaths {
    public static let label = "org.cloudmacmonitor.probe"
    public static let job = "system/" + label
    public static let app = "/Applications/Cloud Mac Monitor Probe.app"
    public static let helper = app + "/Contents/MacOS/MaintenanceProbeHelper"
    public static let plist = "/Library/LaunchDaemons/" + label + ".plist"
    public static let root = "/Library/Application Support/CloudMacMonitorProbe"
}

public enum PrototypeStateError: Error { case unrecognizedOutput }

public enum PrototypeStateParser {
    /// macOS versions render overrides as either enabled/disabled or true/false.
    public static func isDisabled(_ output: String) throws -> Bool {
        guard output.contains("disabled services = {") else { throw PrototypeStateError.unrecognizedOutput }
        var states: [Bool] = []
        for line in output.split(separator: "\n") {
            let fields = line.components(separatedBy: "=>")
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces) == "\"" + PrototypePaths.label + "\"" else { continue }
            switch fields[1].trimmingCharacters(in: .whitespaces) {
            case "true", "disabled": states.append(true)
            case "false", "enabled": states.append(false)
            default: throw PrototypeStateError.unrecognizedOutput
            }
        }
        guard states.count <= 1 else { throw PrototypeStateError.unrecognizedOutput }
        return states.first ?? false // No override; the prototype plist has no Disabled key.
    }
}
