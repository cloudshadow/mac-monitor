import Darwin
import Foundation
import HistoryStore
import MacCollectors
import MonitorCore
import MonitorIPC

public final class AgentRuntime: @unchecked Sendable {
  public let state: StateStore, history: HistoryDatabase, auth: AuthService, metrics: MetricStore
  public private(set) var server: MonitorHTTPServer
  private var scheduler: Scheduler!, control: LocalControlServer?
  private let lockFd: Int32, root: String, webRootForLAN: String
  private let requestExit: @Sendable () -> Void
  private let stopping = Locked(false)
  private let lan = Locked((address: "", error: "starting"))
  public static let lanInterface = LanNetwork.defaultInterfaceName
  private var lanServer: MonitorHTTPServer?
  private var powerWatcher: SystemPowerWatcher?
  private var powerObservers: [NSObjectProtocol] = []
  private var networkTimer: DispatchSourceTimer?
  private var certificateCheckAt = Date.distantPast
  private let lifecycleQueue = DispatchQueue(label: "org.cloudmacmonitor.lifecycle")
  public private(set) var address = ""
  private var configuredPort = 8765
  public init(root: String, webRoot: String, requestExit: @escaping @Sendable () -> Void = {}) throws {
    self.requestExit = requestExit
    guard geteuid() != 0 else { throw APIError(403, "ordinaryOwnerRequired") }
    self.root = root
    webRootForLAN = webRoot
    if root == InstallationLayout.data {
      let configURL = URL(
        fileURLWithPath: InstallationLayout.configuration)
      var info = stat()
      guard lstat(configURL.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_mode & 0o022 == 0
      else { throw APIError(503, "unsafeInstallation") }
      let parent = configURL.deletingLastPathComponent().path
      guard lstat(parent, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_mode & 0o022 == 0
      else { throw APIError(503, "unsafeInstallation") }
      let config = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: configURL))
      guard config["ownerUid"].number == Double(geteuid()), let name = config["ownerName"].string,
        let record = getpwnam(name), record.pointee.pw_uid == geteuid()
      else { throw APIError(503, "ownerIdentityMismatch") }
      try OwnerIdentity.verify(
        name: name, uid: geteuid(), generatedUID: config["ownerGuid"].string ?? "")
    }
    try Self.directory(root)
    try Self.directory(root + "/run")
    lockFd = open(root + "/run/agent.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockFd >= 0, flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
      throw APIError(409, "agentAlreadyRunning")
    }
    try StartupGuard.record(root: root)
    var lockInfo = stat()
    guard fstat(lockFd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
      lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1
    else {
      close(lockFd)
      throw APIError(503, "unsafeDataPath")
    }
    state = StateStore(path: root + "/state.sqlite")
    history = HistoryDatabase(path: root + "/history.sqlite")
    auth = try AuthService(store: state)
    metrics = MetricStore(history: history)
    server = MonitorHTTPServer(auth: auth, metrics: metrics, history: history, webRoot: webRoot)
    scheduler = Scheduler(
      clock: { HardwareProbe.monotonicNs },
      collect: { [metrics] channel, interval in metrics.collect(channel, interval: interval) },
      discontinuity: { [metrics] in metrics.reset() })
  }
  private static func directory(_ path: String) throws {
    var info = stat()
    if lstat(path, &info) != 0 {
      guard errno == ENOENT, mkdir(path, 0o700) == 0 else { throw APIError(503, "unsafeDataPath") }
      guard lstat(path, &info) == 0 else { throw APIError(503, "unsafeDataPath") }
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw APIError(503, "unsafeDataPath") }
  }
  public func start(port: Int? = nil) throws {
    let saved = (try? state.setting("listenPort")).flatMap { Int($0) }
    let preferred = port ?? saved.flatMap { (1...65535).contains($0) ? $0 : nil } ?? 8765
    guard (0...65535).contains(preferred) else { throw APIError(400, "invalidPort") }
    configuredPort = preferred
    _ = nice(10)
    address = "http://127.0.0.1:\(try server.start(port: preferred))"
    control = try LocalControlServer(path: root + "/run/control.sock", ownerUid: geteuid()) {
      [weak self] request, _ in
      guard let self else { throw APIError(503, "serviceUnavailable") }
      return try await self.command(request)
    }
    control?.start()
    scheduler.start()
    for notification in [
      Notification.Name.NSProcessInfoPowerStateDidChange,
      ProcessInfo.thermalStateDidChangeNotification,
    ] {
      powerObservers.append(
        NotificationCenter.default.addObserver(forName: notification, object: nil, queue: nil) {
          [weak self] _ in self?.applyPowerPolicy()
        })
    }
    applyPowerPolicy()
    powerWatcher = SystemPowerWatcher { [weak self] sleeping in
      guard let self, !self.stopping.withLock({ $0 }) else { return }
      if sleeping { self.scheduler.suspend() } else { self.scheduler.resume() }
    }
    powerWatcher?.start()
    let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
    timer.schedule(deadline: .now() + 30, repeating: .seconds(30), leeway: .seconds(3))
    let stabilized = Locked(false)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if stabilized.withLock({ value in
        if value { return false }
        value = true
        return true
      }) {
        StartupGuard.stable(root: self.root)
      }
      self.reconcileLAN()
    }
    networkTimer = timer
    timer.resume()
    lifecycleQueue.async { [weak self] in self?.reconcileLAN() }
  }
  public func command(_ request: JSONValue) async throws -> JSONValue {
    switch request["command"].string {
    case "status":
      return lifecycleQueue.sync { statusSnapshot() }
    case "setPort":
      guard let number = request["port"].number, number.isFinite,
        number.rounded() == number, (1...65535).contains(number)
      else { throw APIError(400, "invalidPort") }
      return try lifecycleQueue.sync {
        guard !stopping.withLock({ $0 }) else { throw APIError(503, "serviceUnavailable") }
        try configurePort(Int(number))
        return statusSnapshot()
      }
    case "setup":
      return .object(["url": .string(address + "/#setup=" + (try auth.issueSetupTicket()))])
    case "recoverState":
      return .object(["url": .string(address + "/#setup=" + (try auth.recoverState()))])
    case "resetPassword":
      try await auth.resetPassword(request["password"].string ?? "")
      return .object(["status": .string("ok")])
    case "changePassword":
      try await auth.changePassword(
        old: request["oldPassword"].string ?? "", new: request["password"].string ?? "")
      return .object(["status": .string("ok")])
    case "history": return try await history.control(request["action"].string ?? "")
    case "shutdown":
      // Owner-only IPC: allow the acknowledgement to leave before closing the control socket.
      stopping.withLock { $0 = true }
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100), execute: requestExit)
      return .object(["stopping": .bool(true), "pid": .number(Double(getpid()))])
    case "prepareStop":
      stopping.withLock { $0 = true }
      scheduler.stop()
      lifecycleQueue.sync {
        server.stopListeners()
        lanServer?.stopListeners()
      }
      try await history.prepareStop()
      StartupGuard.stable(root: root)
      stopping.withLock { $0 = true }
      return .object(["ready": .bool(true)])
    default: throw APIError(400, "invalidCommand")
    }
  }
  static func savedDataBytes(root: String) -> Int64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    guard let files = FileManager.default.enumerator(
      at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys
    ) else { return 0 }
    return files.reduce(0) { total, item in
      guard let url = item as? URL,
        let value = try? url.resourceValues(forKeys: Set(keys)),
        value.isRegularFile == true, value.isSymbolicLink != true
      else { return total }
      return total + Int64(value.fileSize ?? 0)
    }
  }
  private func statusSnapshot() -> JSONValue {
    let actualPort = URLComponents(string: address)?.port ?? 0
    return .object([
      "address": .string(address), "ownerUid": .number(Double(geteuid())),
      "configuredPort": .number(Double(configuredPort)),
      "actualPort": .number(Double(actualPort)),
      "portFallback": .bool(configuredPort != 0 && actualPort != configuredPort),
      "recoveryRequired": .bool(state.recoveryRequired), "history": history.status(),
      "savedDataBytes": .number(Double(Self.savedDataBytes(root: root))),
      "readyToStop": .bool(stopping.withLock { $0 }),
      "lanAddress": .string(lan.withLock { $0.address }),
      "lanInterface": .string(Self.lanInterface),
      "lanError": .string(lan.withLock { $0.error }),
      "caCertificate": .string(root + "/secrets/ca.pem"),
      "interfaces": .array(LanNetwork.interfaces().map {
        .object(["name": .string($0.name), "address": .string($0.address)])
      }),
    ])
  }
  /// Bind both new listeners before committing, so a rejected change keeps the current addresses.
  private func configurePort(_ port: Int) throws {
    let currentPort = URLComponents(string: address)?.port
    if currentPort == port {
      try state.set("listenPort", String(port))
      configuredPort = port
      reconcileLAN()
      return
    }
    let replacement = MonitorHTTPServer(
      auth: auth, metrics: metrics, history: history, webRoot: webRootForLAN,
      viewers: server.viewers, budget: server.budget, queryLimits: server.queryLimits)
    var replacementLAN: MonitorHTTPServer?
    var committed = false
    defer {
      if !committed {
        replacement.shutdown()
        replacementLAN?.shutdown()
      }
    }
    do { _ = try replacement.start(port: port, allowPortFallback: false) }
    catch {
      if (error as? APIError)?.code == "portInUse" { throw APIError(409, "localPortInUse") }
      throw APIError(503, "portBindFailed")
    }
    var lanAddress = ""
    if let chosen = LanNetwork.defaultInterface(in: LanNetwork.interfaces()) {
      let identity = try TLSIdentity(directory: root + "/secrets", address: chosen.address)
      let listener = MonitorHTTPServer(
        auth: auth, metrics: metrics, history: history, webRoot: webRootForLAN,
        viewers: server.viewers, budget: server.budget, queryLimits: server.queryLimits)
      replacementLAN = listener
      do {
        _ = try listener.start(host: chosen.address, port: port, certificate: identity.certificate,
          privateKey: identity.privateKey, allowPortFallback: false)
      } catch {
        if (error as? APIError)?.code == "portInUse" { throw APIError(409, "lanPortInUse") }
        throw APIError(503, "portBindFailed")
      }
      lanAddress = "https://\(chosen.address):\(port)"
    }
    try state.set("listenPort", String(port))
    let previous = server, previousLAN = lanServer
    server = replacement
    lanServer = replacementLAN
    configuredPort = port
    address = "http://127.0.0.1:\(port)"
    lan.withLock { $0 = (lanAddress, lanAddress.isEmpty ? "networkUnavailable" : "") }
    certificateCheckAt = Date()
    committed = true
    previous.shutdown()
    previousLAN?.shutdown()
  }
  private func applyPowerPolicy() {
    scheduler.configure(
      PowerPolicy.intervals(
        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermal: ProcessInfo.processInfo.thermalState.rawValue))
  }
  private func reconcileLAN() {
    guard !stopping.withLock({ $0 }) else { return }
    let interface = Self.lanInterface
    guard let selected = LanNetwork.defaultInterface(in: LanNetwork.interfaces()) else {
      lanServer?.shutdown()
      lanServer = nil
      lan.withLock { $0 = ("", "networkUnavailable") }
      return
    }
    let sameAddress = lan.withLock { $0.address.hasPrefix("https://" + selected.address + ":") }
    if !sameAddress {
      lanServer?.shutdown()
      lanServer = nil
      lan.withLock { $0.address = "" }
    }
    if !sameAddress
      || Date().timeIntervalSince(certificateCheckAt) >= 86400
    {
      do { try awaitlessEnableLAN(interface: interface) } catch {
        lan.withLock { $0.error = (error as? APIError)?.code == "portInUse"
          ? "lanPortInUse" : (error as? APIError)?.code ?? "tlsUnavailable" }
      }
    }
  }
  private func awaitlessEnableLAN(interface: String) throws {
    let choices = LanNetwork.interfaces()
    guard let chosen = LanNetwork.defaultInterface(in: choices) else { throw APIError(503, "networkUnavailable") }
    let identity = try TLSIdentity(directory: root + "/secrets", address: chosen.address)
    let listener = MonitorHTTPServer(
      auth: auth, metrics: metrics, history: history, webRoot: webRootForLAN,
      viewers: server.viewers, budget: server.budget, queryLimits: server.queryLimits)
    let previous = lanServer
    let preferredPort = URLComponents(string: address)?.port ?? 8765
    let port: Int
    do {
      port = try listener.start(
        host: chosen.address, port: preferredPort, certificate: identity.certificate,
        privateKey: identity.privateKey, allowPortFallback: false, beforeBind: { previous?.shutdown() })
    } catch {
      listener.shutdown()
      lanServer = nil
      lan.withLock { $0.address = "" }
      throw error
    }
    certificateCheckAt = Date()
    lanServer = listener
    lan.withLock { $0 = ("https://\(chosen.address):\(port)", "") }
  }
  public func shutdown() async {
    stopping.withLock { $0 = true }
    networkTimer?.cancel()
    for observer in powerObservers { NotificationCenter.default.removeObserver(observer) }
    scheduler.stop()
    control?.stop()
    lifecycleQueue.sync {
      server.shutdown()
      lanServer?.shutdown()
      lanServer = nil
    }
    try? await history.prepareStop()
    StartupGuard.stable(root: root)
    flock(lockFd, LOCK_UN)
    close(lockFd)
  }
}
