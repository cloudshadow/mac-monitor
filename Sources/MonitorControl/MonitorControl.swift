import CoreImage.CIFilterBuiltins
import CoreServices
import Darwin
import MonitorCore
import MonitorIPC
import SwiftUI

@MainActor final class ControlModel: ObservableObject {
  static var current: ControlModel?
  @Published var status: JSONValue = .null
  @Published var serviceStatus: JSONValue = .null
  @Published var error = ""
  @Published var busy = false
  @Published var pairingURL = ""
  @Published var certificate = ""
  @Published var devices: [JSONValue] = []
  @Published var update: AvailableUpdate?
  var reportShutdownFailure: (String) -> Void = { message in
    let alert = NSAlert()
    alert.messageText = NativeKeys.title()
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
  private let socketPath: String, owner: uid_t
  init(socketPath testPath: String? = nil, ownerUid testOwner: uid_t? = nil) {
    if let testPath, let testOwner {
      socketPath = testPath
      owner = testOwner
    } else if let index = CommandLine.arguments.firstIndex(of: "--data-root"),
      index + 1 < CommandLine.arguments.count
    {
      socketPath = CommandLine.arguments[index + 1] + "/run/control.sock"
      owner = getuid()
    } else {
      socketPath = "/Library/Application Support/CloudMacMonitor/data/run/control.sock"
      let url = URL(
        fileURLWithPath: "/Library/Application Support/CloudMacMonitor/installation.json")
      let config = (try? Data(contentsOf: url)).flatMap {
        try? JSONDecoder().decode(JSONValue.self, from: $0)
      }
      owner = uid_t(config?["ownerUid"].number ?? Double(UInt32.max))
    }
    Self.current = self
  }
  func send(
    _ command: String, arguments: [String: JSONValue] = [:],
    onFailure: ((any Error) -> Void)? = nil, then: ((JSONValue) -> Void)? = nil
  ) {
    guard !busy else { return }
    busy = true
    error = ""
    let path = socketPath
    let uid = owner
    var request = arguments
    request["command"] = .string(command)
    let body = JSONValue.object(request)
    Task {
      do {
        let result = try await Task.detached {
          try LocalControl.request(path: path, ownerUid: uid, body: body)
        }.value
        then?(result)
      } catch {
        if command == "status" { status = .null }
        self.error = command == "status"
          ? NativeKeys.serviceUnavailable(code: Self.code(error))
          : NativeKeys.actionFailed(code: Self.code(error))
        busy = false
        onFailure?(error)
        return
      }
      busy = false
    }
  }
  func quit(_ completion: @escaping (Bool) -> Void) {
    let path = socketPath, uid = owner
    Task {
      do {
        try await Task.detached {
          guard FileManager.default.fileExists(atPath: path) else { return }
          let response = try LocalControl.request(path: path, ownerUid: uid, body: .object(["command": .string("shutdown")]))
          guard let number = response["pid"].number, number > 1, number <= Double(Int32.max) else { throw APIError(503, "controlUnavailable") }
          let pid = pid_t(number)
          // Confirm actual process exit, not merely removal of its control socket.
          let deadline = Date().addingTimeInterval(7)
          while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
          guard kill(pid, 0) != 0, errno == ESRCH else { throw APIError(503, "controlTimeout") }
        }.value
        completion(true)
      } catch {
        // A stale socket or failed Agent must never trap the user in the UI.
        let message = NativeKeys.quitFailed(code: Self.code(error))
        self.error = message
        reportShutdownFailure(message)
        completion(true)
      }
    }
  }
  func refresh() { send("status", then: { self.status = $0 }) }
  func openMonitor() {
    // Re-read the address: it may be missing or stale after stopping/restarting.
    send("status", onFailure: { error in
      if Self.code(error) == "controlUnavailable", self.owner == getuid(),
        FileManager.default.fileExists(atPath: InstallationLayout.maintenance) {
        self.maintenance("start", openWhenReady: true)
      }
    }, then: { result in
      self.status = result
      if let value = result["address"].string, let url = URL(string: value),
        url.scheme == "http", url.host == "127.0.0.1" {
        if !NSWorkspace.shared.open(url) { self.error = NativeKeys.browserFailed() }
      } else { self.error = NativeKeys.serviceUnavailable(code: "addressUnavailable") }
    })
  }
  private static func code(_ error: any Error) -> String {
    (error as? APIError)?.code ?? "controlUnavailable"
  }
  func pair() {
    send("pair", then: {
      self.pairingURL = $0["url"].string ?? ""
      self.certificate = $0["caCertificate"].string ?? ""
    })
  }
  func checkUpdates() {
    guard !busy else { return }
    busy = true
    Task {
      do { update = try await UpdateCoordinator.check() } catch { self.error = NativeKeys.error() }
      busy = false
    }
  }
  func maintenance(_ action: String, openWhenReady: Bool = false) {
    guard
      ["status", "enable", "start", "disable", "stop", "uninstall", "uninstallData"].contains(
        action), !busy
    else { return }
    let app = InstallationLayout.maintenance
    let script = "do shell script \"'\(app)' '\(action)' || true\" with administrator privileges"
    busy = true
    error = ""
    // Runs in this app; enum-only arguments enter the fixed privileged executable.
    Task {
      // Authorization/launchctl can take seconds. Keep the AppKit event loop free.
      let value = await Task.detached { () -> JSONValue? in
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let string = result?.stringValue,
          let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
      }.value
      if let value {
        if value["error"] != .null {
          serviceStatus = value["actual"]
          error = NativeKeys.actionFailed(code: value["error"]["code"].string ?? "maintenanceFailed")
        } else { serviceStatus = value }
      } else { error = NativeKeys.error() }
      busy = false
      if value?["error"] == .null, ["start", "enable"].contains(action) {
        // launchctl returning successfully does not mean IPC is ready yet.
        if await refreshAfterStart(), openWhenReady { openMonitor() }
      } else if ["stop", "uninstall", "uninstallData"].contains(action) {
        status = .null
      }
    }
  }
  private func refreshAfterStart() async -> Bool {
    busy = true
    defer { busy = false }
    let path = socketPath, uid = owner
    let deadline = Date().addingTimeInterval(7)
    while Date() < deadline {
      do {
        status = try await Task.detached {
          try LocalControl.request(path: path, ownerUid: uid, body: .object(["command": .string("status")]))
        }.value
        error = ""
        return true
      } catch {
        self.error = NativeKeys.serviceUnavailable(code: Self.code(error))
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    status = .null
    return false
  }
}
@MainActor final class ControlAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Logout/restart closes the UI without changing the independent system service.
    if let reason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue,
      [AEKeyword(kAEQuitAll), AEKeyword(kAEShutDown), AEKeyword(kAERestart), AEKeyword(kAEReallyLogOut)].contains(reason) {
      return .terminateNow
    }
    guard let model = ControlModel.current else { return .terminateNow }
    model.quit { sender.reply(toApplicationShouldTerminate: $0) }
    return .terminateLater
  }
}
@main struct MonitorControlApp: App {
  @NSApplicationDelegateAdaptor(ControlAppDelegate.self) private var delegate
  var body: some Scene {
    WindowGroup("Cloud Mac Monitor") { ControlView() }.windowResizability(.contentSize)
  }
}
struct ControlView: View {
  @StateObject private var model = ControlModel()
  @AppStorage("language") private var language = "en"
  @State private var password = ""
  @State private var interface = ""
  @State private var showClear = false
  @State private var showUninstall = false
  @State private var showRecovery = false
  @State private var deleteData = false
  private func serviceFlag(_ key: String) -> String {
    guard let value = model.serviceStatus[key].bool else { return "—" }
    return value ? NativeKeys.yes() : NativeKeys.no()
  }
  private var serviceSummary: String {
    NativeKeys.serviceState(
      boot: serviceFlag("bootEnabled"), loaded: serviceFlag("loaded"),
      running: serviceFlag("running"), system: serviceFlag("systemEnabled"))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(NativeKeys.title()).font(.title2)
          Text(NativeKeys.version(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
          )).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Picker(NativeKeys.language(), selection: $language) {
          ForEach(NativeLocalization.languages, id: \.self) { meta in
            Text(meta["nativeName"].string ?? "").tag(meta["tag"].string ?? "en")
          }
        }.frame(width: 150)
      }
      Text(model.status["address"].string ?? NativeKeys.status(state: "—")).foregroundStyle(
        .secondary).textSelection(.enabled)
      HStack {
        Button(NativeKeys.refresh()) { model.refresh() }
        Button(NativeKeys.open()) { model.openMonitor() }
      }
      Text(NativeKeys.refreshHelp()).font(.caption).foregroundStyle(.secondary)
      if model.status["recoveryRequired"].bool == true {
        Button(NativeKeys.recover()) { showRecovery = true }
      }
      Divider()
      HStack {
        SecureField(NativeKeys.password(), text: $password)
        Button(NativeKeys.reset()) {
          let value = password
          password = ""
          model.send("resetPassword", arguments: ["password": .string(value)])
        }.disabled(password.count < 12 || password.count > 128)
      }
      HStack {
        Button(NativeKeys.pause()) {
          model.send("history", arguments: ["action": .string("pause")])
        }
        Button(NativeKeys.resume()) {
          model.send("history", arguments: ["action": .string("resume")])
        }
        Button(NativeKeys.clear(), role: .destructive) { showClear = true }
      }
      Divider()
      HStack {
        Picker(NativeKeys.lanInterface(), selection: $interface) {
          Text("—").tag("")
          ForEach(model.status["interfaces"].array, id: \.self) { value in
            Text((value["name"].string ?? "") + " · " + (value["address"].string ?? "")).tag(
              value["name"].string ?? "")
          }
        }
        Button(NativeKeys.lan()) {
          model.send("lan", arguments: ["enabled": .bool(true), "interface": .string(interface)])
        }
        Button(NativeKeys.disableLAN()) { model.send("lan", arguments: ["enabled": .bool(false)]) }
        Button(NativeKeys.pair()) { model.pair() }
      }
      Text(NativeKeys.lanHelp()).font(.caption).foregroundStyle(.secondary)
      if let address = model.status["lanAddress"].string, !address.isEmpty {
        Text(address).font(.caption).textSelection(.enabled)
      }
      if !model.pairingURL.isEmpty {
        HStack(alignment: .top) {
          if let image = qr(model.pairingURL) {
            Image(nsImage: image).interpolation(.none).resizable().frame(width: 140, height: 140)
          }
          VStack(alignment: .leading) {
            Text(model.pairingURL).textSelection(.enabled).font(.caption)
            Button("CA") {
              NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: model.certificate)
              ])
            }
          }
        }
      }
      Button(NativeKeys.devices()) { model.send("devices", then: { model.devices = $0.array }) }
      ForEach(model.devices, id: \.self) { value in
        HStack {
          Text(value["label"].string ?? "")
          Spacer()
          Button(NativeKeys.revoke()) { model.send("revokeDevice", arguments: ["id": value["id"]]) }
        }
      }
      Divider()
      HStack {
        Button(NativeKeys.enable()) { model.maintenance("enable") }
        Button(NativeKeys.start()) { model.maintenance("start") }
        Button(NativeKeys.disable()) { model.maintenance("disable") }
        Button(NativeKeys.stop()) { model.maintenance("stop") }
      }
      if model.serviceStatus != .null {
        Text(serviceSummary).font(.caption)
      }
      HStack {
        Button(NativeKeys.update()) { model.checkUpdates() }
        if let update = model.update {
          Text(update.version)
          Button(NativeKeys.copyCommand()) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(update.command, forType: .string)
          }
        }
      }
      Text(NativeKeys.background()).font(.caption).foregroundStyle(.secondary)
      Toggle(NativeKeys.deleteData(), isOn: $deleteData)
      Button(NativeKeys.uninstall(), role: .destructive) { showUninstall = true }
      if !model.error.isEmpty { Text(model.error).foregroundStyle(.red) }
      if model.busy { ProgressView() }
    }.padding(24).frame(width: 640).disabled(model.busy)
      .onAppear { model.refresh() }
      .alert(NativeKeys.recover(), isPresented: $showRecovery) {
        Button(NativeKeys.recover(), role: .destructive) {
          model.send("recoverState", then: { result in
            if let value = result["url"].string, let url = URL(string: value) {
              NSWorkspace.shared.open(url)
            }
          })
        }
        Button(NativeKeys.cancel(), role: .cancel) {}
      }
      .alert(NativeKeys.clear(), isPresented: $showClear) {
        Button(NativeKeys.clear(), role: .destructive) {
          model.send("history", arguments: ["action": .string("clear")])
        }
        Button(NativeKeys.cancel(), role: .cancel) {}
      }
      .alert(NativeKeys.uninstall(), isPresented: $showUninstall) {
        Toggle(NativeKeys.deleteData(), isOn: $deleteData)
        Button(NativeKeys.uninstall(), role: .destructive) {
          model.maintenance(deleteData ? "uninstallData" : "uninstall")
        }
        Button(NativeKeys.cancel(), role: .cancel) {}
      }
  }
  private func qr(_ value: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: 140, height: 140))
  }
}
