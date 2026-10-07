import CoreServices
import Darwin
import MonitorCore
import MonitorIPC
import SwiftUI

@MainActor final class ControlModel: ObservableObject {
  static var current: ControlModel?
  @Published var status: JSONValue = .null
  @Published var serviceStatus: JSONValue = .null
  @Published var serviceError = ""
  private var inspectingService = false
  private var serviceRevision = 0
  private let serviceConfigurationPath: String?
  @Published var error = ""
  @Published var busy = false
  @Published var update: AvailableUpdate?
  @Published var updateStatus = ""
  @Published var checkingUpdates = false
  @Published var installingUpdate = false
  var relaunching = false
  var fetchUpdate: @MainActor () async throws -> AvailableUpdate? = { try await UpdateCoordinator.check() }
  var applyUpdate: @MainActor (AvailableUpdate) async throws -> Void = { try await UpdateCoordinator.install($0) }
  var reopenUpdatedApp: @MainActor () async throws -> Void = {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: InstallationLayout.launcher), configuration: configuration)
    NSApp.terminate(nil)
  }
  private var refreshing = false
  private var controlRevision = 0
  var reportShutdownFailure: (String) -> Void = { message in
    let alert = NSAlert()
    alert.messageText = NativeKeys.title()
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
  private let socketPath: String, owner: uid_t
  init(socketPath testPath: String? = nil, ownerUid testOwner: uid_t? = nil) {
    serviceConfigurationPath = testPath == nil && !CommandLine.arguments.contains("--data-root")
      ? InstallationLayout.configuration : nil
    if let testPath, let testOwner {
      socketPath = testPath
      owner = testOwner
    } else if let index = CommandLine.arguments.firstIndex(of: "--data-root"),
      index + 1 < CommandLine.arguments.count
    {
      socketPath = CommandLine.arguments[index + 1] + "/run/control.sock"
      owner = getuid()
    } else {
      socketPath = InstallationLayout.data + "/run/control.sock"
      let url = URL(
        fileURLWithPath: InstallationLayout.configuration)
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
    controlRevision += 1
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
  var bootEnabled: Bool? {
    guard let boot = serviceStatus["bootEnabled"].bool, let system = serviceStatus["systemEnabled"].bool else { return nil }
    return boot && system
  }
  var running: Bool? { serviceStatus["running"].bool }
  func toggleBoot() {
    guard let bootEnabled else { return }
    maintenance(bootEnabled ? "disable" : "enable")
  }
  func toggleService() {
    guard let running else { return }
    maintenance(running ? "stop" : "start")
  }
  func refreshServiceState() {
    guard let path = serviceConfigurationPath, !inspectingService, !busy, !installingUpdate else { return }
    inspectingService = true
    let revision = serviceRevision
    Task {
      defer { inspectingService = false }
      do {
        let value = try await Task.detached {
          let config = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
          return try ServiceState.inspect(config: config)
        }.value
        guard revision == serviceRevision else { return }
        if serviceStatus != value { serviceStatus = value }
        if !serviceError.isEmpty { serviceError = "" }
      } catch {
        guard revision == serviceRevision else { return }
        serviceStatus = .null
        serviceError = NativeKeys.actionFailed(code: "unknownServiceState")
      }
    }
  }
  func refresh(silently: Bool = false) {
    guard silently else {
      refreshServiceState()
      send("status", then: { self.status = $0 })
      return
    }
    guard !busy, !refreshing, !installingUpdate else { return }
    refreshServiceState()
    refreshing = true
    let revision = controlRevision
    let path = socketPath, uid = owner
    Task {
      defer { refreshing = false }
      do {
        let result = try await Task.detached {
          try LocalControl.request(path: path, ownerUid: uid, body: .object(["command": .string("status")]))
        }.value
        guard !busy, revision == controlRevision else { return }
        if status != result { status = result }
      } catch {
        guard !busy, revision == controlRevision else { return }
        if status != .null { status = .null }
        self.error = NativeKeys.serviceUnavailable(code: Self.code(error))
      }
    }
  }
  func configurePort(_ input: String) {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let port = Int(text), (1...65535).contains(port) else {
      error = NativeKeys.invalidPort()
      return
    }
    send("setPort", arguments: ["port": .number(Double(port))], onFailure: { error in
      switch Self.code(error) {
      case "localPortInUse": self.error = NativeKeys.localPortInUse(port: String(port))
      case "lanPortInUse": self.error = NativeKeys.lanPortInUse(port: String(port))
      case "portBindFailed": self.error = NativeKeys.portBindFailed(port: String(port))
      case "invalidPort": self.error = NativeKeys.invalidPort()
      default: break
      }
    }, then: { self.status = $0 })
  }
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
  func checkUpdates() {
    guard !checkingUpdates, !installingUpdate else { return }
    checkingUpdates = true
    update = nil
    updateStatus = ""
    Task {
      defer { checkingUpdates = false }
      do {
        update = try await fetchUpdate()
        if update == nil { updateStatus = NativeKeys.upToDate() }
      } catch {
        updateStatus = NativeKeys.updateFailed(reason: error.localizedDescription)
      }
    }
  }
  func installUpdate() {
    guard let update, !busy, !checkingUpdates, !installingUpdate else { return }
    installingUpdate = true
    updateStatus = NativeKeys.installingUpdate()
    Task {
      defer { installingUpdate = false }
      do {
        try await applyUpdate(update)
        relaunching = true
        try await reopenUpdatedApp()
      } catch {
        updateStatus = relaunching
          ? NativeKeys.updateRestartFailed(reason: error.localizedDescription)
          : NativeKeys.updateInstallFailed(reason: error.localizedDescription)
        relaunching = false
      }
    }
  }
  func maintenance(_ action: String, openWhenReady: Bool = false) {
    guard
      ["status", "enable", "start", "disable", "stop", "uninstall", "uninstallData"].contains(
        action), !busy
    else { return }
    serviceRevision += 1
    controlRevision += 1
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
        serviceError = ""
        if value["error"] != .null {
          serviceStatus = value["actual"]
          error = NativeKeys.actionFailed(code: value["error"]["code"].string ?? "maintenanceFailed")
        } else { serviceStatus = value }
      } else { error = NativeKeys.error() }
      busy = false
      if value?["error"] == .null, action == "start" {
        // launchctl returning successfully does not mean IPC is ready yet.
        let ready = await refreshAfterStart()
        refreshServiceState()
        if ready, openWhenReady { openMonitor() }
      } else if value?["error"] == .null, ["stop", "uninstall", "uninstallData"].contains(action) {
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
    guard let model = ControlModel.current, !model.relaunching else { return .terminateNow }
    model.quit { sender.reply(toApplicationShouldTerminate: $0) }
    return .terminateLater
  }
}
@main struct MonitorControlApp: App {
  @NSApplicationDelegateAdaptor(ControlAppDelegate.self) private var delegate
  var body: some Scene {
    WindowGroup("Mac Monitor") { ControlView() }.windowResizability(.contentSize)
  }
}
struct ControlView: View {
  @StateObject private var model = ControlModel()
  @AppStorage("language") private var language = "en"
  @State private var password = ""
  @State private var port = "8765"
  @State private var showClear = false
  @State private var showUninstall = false
  @State private var showRecovery = false
  @State private var deleteData = false
  private var serviceSummary: String {
    NativeKeys.serviceState(
      boot: model.bootEnabled.map { $0 ? NativeKeys.yes() : NativeKeys.no() } ?? "—",
      running: model.running.map { $0 ? NativeKeys.yes() : NativeKeys.no() } ?? "—")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let logo = NSImage(contentsOf: url) {
          Image(nsImage: logo).resizable().scaledToFit().frame(width: 44, height: 44)
        }
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
      HStack {
        Text(NativeKeys.port())
        TextField(NativeKeys.port(), text: $port).frame(width: 90)
          .textFieldStyle(.roundedBorder)
        Button(NativeKeys.applyPort()) { model.configurePort(port) }
          .disabled(model.status == .null)
      }
      Text(NativeKeys.portHelp()).font(.caption).foregroundStyle(.secondary)
      if model.status["portFallback"].bool == true {
        Text(NativeKeys.portFallback(
          actual: String(Int(model.status["actualPort"].number ?? 0)),
          configured: String(Int(model.status["configuredPort"].number ?? 8765))
        )).font(.caption).foregroundStyle(.orange)
      }
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
      if let bytes = model.status["savedDataBytes"].number {
        Text(NativeKeys.savedData(size: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
      }
      if let bytes = model.status["history"]["diskBytes"].number {
        Text(NativeKeys.historyData(size: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
          .font(.caption).foregroundStyle(.secondary)
      }
      if model.status["history"]["state"].string == "resetting" {
        HStack { ProgressView().controlSize(.small); Text(NativeKeys.cleaningData()) }
      }
      if let code = model.status["history"]["error"].string {
        Text(NativeKeys.actionFailed(code: code)).foregroundStyle(.red)
      }
      HStack {
        Button(NativeKeys.pause()) {
          model.send("history", arguments: ["action": .string("pause")])
        }
        Button(NativeKeys.resume()) {
          model.send("history", arguments: ["action": .string("resume")])
        }
        Button(NativeKeys.clear(), role: .destructive) { showClear = true }
      }.disabled(model.status == .null || model.status["history"]["state"].string == "resetting")
      Text(NativeKeys.clearHelp()).font(.caption).foregroundStyle(.secondary)
      Divider()
      Text(NativeKeys.lanHelp()).font(.caption).foregroundStyle(.secondary)
      if let address = model.status["lanAddress"].string, !address.isEmpty {
        Text(address).textSelection(.enabled)
        if let certificate = model.status["caCertificate"].string {
          Text(NativeKeys.certificate(path: certificate)).font(.caption).textSelection(.enabled)
        }
      } else {
        Text(model.status["lanError"].string == "lanPortInUse"
          ? NativeKeys.lanPortInUse(port: String(Int(model.status["actualPort"].number ?? 8765)))
          : NativeKeys.lanUnavailable(code: model.status["lanError"].string ?? "networkUnavailable"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        Button(model.bootEnabled.map { $0 ? NativeKeys.disable() : NativeKeys.enable() } ?? NativeKeys.checking()) {
          model.toggleBoot()
        }.disabled(model.bootEnabled == nil)
        Button(model.running.map { $0 ? NativeKeys.stop() : NativeKeys.start() } ?? NativeKeys.checking()) {
          model.toggleService()
        }.disabled(model.running == nil)
      }
      if !model.serviceError.isEmpty { Text(model.serviceError).font(.caption).foregroundStyle(.red) }
      if model.serviceStatus != .null {
        Text(serviceSummary).font(.caption)
      }
      HStack {
        Button(NativeKeys.update()) { model.checkUpdates() }.disabled(model.checkingUpdates)
        if model.checkingUpdates { ProgressView().controlSize(.small).accessibilityLabel(NativeKeys.update()) }
        if let update = model.update {
          Text(update.version)
          Button(NativeKeys.installUpdate()) { model.installUpdate() }.disabled(model.checkingUpdates)
          if model.installingUpdate { ProgressView().controlSize(.small).accessibilityLabel(NativeKeys.installUpdate()) }
          Button(NativeKeys.copyCommand()) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(update.command, forType: .string)
          }
        }
      }
      if !model.updateStatus.isEmpty { Text(model.updateStatus).font(.caption) }
      Text(NativeKeys.background()).font(.caption).foregroundStyle(.secondary)
      Toggle(NativeKeys.deleteData(), isOn: $deleteData)
      Button(NativeKeys.uninstall(), role: .destructive) { showUninstall = true }
      if !model.error.isEmpty { Text(model.error).foregroundStyle(.red) }
      if model.busy { ProgressView() }
    }.padding(24).frame(width: 640).disabled(model.busy || model.installingUpdate)
      .onChange(of: model.status["configuredPort"].number, initial: true) { _, value in
        if let value, value > 0 { port = String(Int(value)) }
      }
      .task {
        model.refresh()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          model.refresh(silently: true)
        }
      }
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
          model.send("history", arguments: ["action": .string("clear")], then: { result in
            if case .object(var status) = model.status {
              status["history"] = result
              model.status = .object(status)
            }
            Task { model.refresh(silently: true) }
          })
        }
        Button(NativeKeys.cancel(), role: .cancel) {}
      } message: {
        Text(NativeKeys.clearHelp())
      }
      .alert(NativeKeys.uninstall(), isPresented: $showUninstall) {
        Toggle(NativeKeys.deleteData(), isOn: $deleteData)
        Button(NativeKeys.uninstall(), role: .destructive) {
          model.maintenance(deleteData ? "uninstallData" : "uninstall")
        }
        Button(NativeKeys.cancel(), role: .cancel) {}
      }
  }
}
