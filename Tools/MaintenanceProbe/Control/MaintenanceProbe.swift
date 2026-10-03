import AppKit
import SwiftUI
import MaintenancePrototype

@main
struct MaintenanceProbeApp: App {
    @State private var output = "Isolated G4 prototype. Only the installed org.cloudmacmonitor.probe task is managed."
    @State private var busy = false
    var body: some Scene {
        WindowGroup("Cloud Mac Monitor · G4") {
            VStack(alignment: .leading, spacing: 16) {
                Text("System authorization probe").font(.title2)
                Text("Install the signed probe bundle with scripts/install-maintenance-probe.sh first. Cancel authorization before any mutation to validate cancellation.")
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(PrototypeAction.allCases, id: \.rawValue) { action in
                        Button(action.rawValue) { run(action) }.disabled(busy)
                    }
                }
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24).frame(width: 680, height: 340)
        }.windowResizability(.contentSize)
    }
    @MainActor
    private func run(_ action: PrototypeAction) {
        busy = true
        defer { busy = false }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: action.appleScript) else { output = "Could not create AppleScript"; return }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            output = code == -128 ? "Authorization cancelled; no helper command executed." : "Authorization/helper failed: \(error)"
        } else { output = result.stringValue ?? "Completed" }
    }
}
