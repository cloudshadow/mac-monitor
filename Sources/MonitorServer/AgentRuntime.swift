import Darwin
import Foundation
import HistoryStore
import MacCollectors
import MonitorCore
import MonitorIPC

public final class AgentRuntime: @unchecked Sendable {
  public let state: StateStore, history: HistoryDatabase, auth: AuthService, metrics: MetricStore,
    server: MonitorHTTPServer
  private var scheduler: Scheduler!, control: LocalControlServer?
  private let lockFd: Int32, root: String, webRootForLAN: String
  private let requestExit: @Sendable () -> Void
  private let stopping = Locked(false)
  private let lan = Locked((address: "", interface: ""))
  private var lanServer: MonitorHTTPServer?
  private var powerWatcher: SystemPowerWatcher?
  private var powerObservers: [NSObjectProtocol] = []
  private var networkTimer: DispatchSourceTimer?
  private var certificateCheckAt = Date.distantPast
  private let lifecycleQueue = DispatchQueue(label: "org.cloudmacmonitor.lifecycle")
  public private(set) var address = ""
  public init(root: String, webRoot: String, requestExit: @escaping @Sendable () -> Void = {}) throws {
    self.requestExit = requestExit
    guard geteuid() != 0 else { throw APIError(403, "ordinaryOwnerRequired") }
    self.root = root
    webRootForLAN = webRoot
    if root == "/Library/Application Support/CloudMacMonitor/data" {
      let configURL = URL(
        fileURLWithPath: "/Library/Application Support/CloudMacMonitor/installation.json")
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
  public func start(port: Int = 8765) throws {
    _ = nice(10)
    address = "http://127.0.0.1:\(try server.start(port: port))"
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
    if (try? state.setting("lanEnabled")) == "true" {
      try? awaitlessEnableLAN(interface: (try? state.setting("lanInterface")) ?? "")
    }
  }
  public func command(_ request: JSONValue) async throws -> JSONValue {
    switch request["command"].string {
    case "status":
      return .object([
        "address": .string(address), "ownerUid": .number(Double(geteuid())),
        "recoveryRequired": .bool(state.recoveryRequired), "history": history.status(),
        "readyToStop": .bool(stopping.withLock { $0 }),
        "lanAddress": .string(lan.withLock { $0.address }),
        "interfaces": .array(
          LanNetwork.interfaces().map {
            .object(["name": .string($0.name), "address": .string($0.address)])
          }),
      ])
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
    case "lan":
      return try await withCheckedThrowingContinuation { continuation in
        lifecycleQueue.async { [self] in
          do {
            if request["enabled"].bool == true {
              try awaitlessEnableLAN(interface: request["interface"].string ?? "")
            } else {
              try state.set("lanEnabled", "false")
              lanServer?.shutdown()
              lanServer = nil
              lan.withLock { $0 = ("", "") }
            }
            continuation.resume(
              returning: .object(["address": .string(lan.withLock { $0.address })]))
          } catch { continuation.resume(throwing: error) }
        }
      }
    case "pair":
      let address = lan.withLock { $0.address }
      guard !address.isEmpty else { throw APIError(409, "lanDisabled") }
      return .object([
        "url": .string(address + "/#pair=" + (try auth.issuePairingTicket())),
        "caCertificate": .string(root + "/secrets/ca.pem"),
      ])
    case "devices": return try state.devices()
    case "revokeDevice":
      try auth.revokeDevice(request["id"].string ?? "")
      return .object(["status": .string("ok")])
    case "shutdown":
      // Owner-only IPC: allow the acknowledgement to leave before closing the control socket.
      stopping.withLock { $0 = true }
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100), execute: requestExit)
      return .object(["stopping": .bool(true), "pid": .number(Double(getpid()))])
    case "prepareStop":
      stopping.withLock { $0 = true }
      scheduler.stop()
      server.stopListeners()
      lifecycleQueue.sync { lanServer?.stopListeners() }
      try await history.prepareStop()
      StartupGuard.stable(root: root)
      stopping.withLock { $0 = true }
      return .object(["ready": .bool(true)])
    default: throw APIError(400, "invalidCommand")
    }
  }
  private func applyPowerPolicy() {
    scheduler.configure(
      PowerPolicy.intervals(
        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermal: ProcessInfo.processInfo.thermalState.rawValue))
  }
  private func reconcileLAN() {
    guard !stopping.withLock({ $0 }), (try? state.setting("lanEnabled")) == "true" else { return }
    let interface = (try? state.setting("lanInterface")) ?? ""
    guard let selected = LanNetwork.interfaces().first(where: { $0.name == interface }) else {
      lanServer?.shutdown()
      lanServer = nil
      lan.withLock { $0.address = "" }
      return
    }
    if !lan.withLock({ $0.address.contains("https://" + selected.address + ":") })
      || Date().timeIntervalSince(certificateCheckAt) >= 86400
    {
      try? awaitlessEnableLAN(interface: interface)
    }
  }
  private func awaitlessEnableLAN(interface: String) throws {
    guard try state.account() != nil else { throw APIError(409, "setupRequired") }
    let choices = LanNetwork.interfaces()
    guard
      let chosen = choices.first(where: { $0.name == interface })
        ?? (interface.isEmpty ? choices.first : nil)
    else { throw APIError(503, "networkUnavailable") }
    let identity = try TLSIdentity(directory: root + "/secrets", address: chosen.address)
    let listener = MonitorHTTPServer(
      auth: auth, metrics: metrics, history: history, webRoot: webRootForLAN,
      viewers: server.viewers, budget: server.budget, queryLimits: server.queryLimits)
    let previous = lanServer
    let preferredPort = URLComponents(string: lan.withLock { $0.address })?.port ?? 8766
    let port: Int
    do {
      port = try listener.start(
        host: chosen.address, port: preferredPort, certificate: identity.certificate,
        privateKey: identity.privateKey, beforeBind: { previous?.shutdown() })
    } catch {
      listener.shutdown()
      lanServer = nil
      lan.withLock { $0.address = "" }
      throw error
    }
    certificateCheckAt = Date()
    do {
      try state.set("lanInterface", chosen.name)
      try state.set("lanEnabled", "true")
    } catch {
      listener.shutdown()
      throw error
    }
    lanServer = listener
    lan.withLock { $0 = ("https://\(chosen.address):\(port)", chosen.name) }
  }
  public func shutdown() async {
    stopping.withLock { $0 = true }
    networkTimer?.cancel()
    for observer in powerObservers { NotificationCenter.default.removeObserver(observer) }
    scheduler.stop()
    control?.stop()
    server.shutdown()
    lifecycleQueue.sync {
      lanServer?.shutdown()
      lanServer = nil
    }
    try? await history.prepareStop()
    StartupGuard.stable(root: root)
    flock(lockFd, LOCK_UN)
    close(lockFd)
  }
}
