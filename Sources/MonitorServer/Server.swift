import Darwin
import Foundation
import HistoryStore
import MonitorCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS

public struct WebRequest: Sendable {
  public let method: String, path: String, query: [String: String], headers: [String: [String]],
    body: JSONValue, ip: String
  public func header(_ name: String) -> String? { headers[name.lowercased()]?.first }
  public var cookies: [String: String] {
    Dictionary(
      (header("cookie") ?? "").split(separator: ";").compactMap { item -> (String, String)? in
        let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        guard pair.count == 2 else { return nil }
        return (String(pair[0]), String(pair[1]))
      }, uniquingKeysWith: { a, _ in a })
  }
}
public struct WebResponse: Sendable {
  let status: Int, body: Data, contentType: String, headers: [(String, String)],
    streamViewer: String?
  static func json(_ value: JSONValue, status: Int = 200, headers: [(String, String)] = []) throws
    -> Self
  {
    Self(
      status: status, body: try value.data(), contentType: "application/json", headers: headers,
      streamViewer: nil)
  }
}
public final class ConnectionBudget: @unchecked Sendable {
  private let counts = Locked((total: 0, tls: 0))
  public init() {}
  func acquire(tls: Bool) -> Bool {
    counts.withLock { value in
      // Browsers open several HTTPS connections in parallel; the total cap also bounds handshakes.
      guard value.total < 16 else { return false }
      value.total += 1
      if tls { value.tls += 1 }
      return true
    }
  }
  func handshakeDone() { counts.withLock { $0.tls -= 1 } }
  func release(handshakePending: Bool) {
    counts.withLock {
      $0.total -= 1
      if handshakePending { $0.tls -= 1 }
    }
  }
}
public final class MonitorHTTPServer: @unchecked Sendable {
  public let auth: AuthService, metrics: MetricStore, history: HistoryDatabase
  public let viewers: ViewerService
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  public let budget: ConnectionBudget
  public let queryLimits: QueryLimits
  private let channels = Locked([any Channel]())
  private let clients = Locked([ObjectIdentifier: any Channel]())
  private let webRoot: String
  public init(
    auth: AuthService, metrics: MetricStore, history: HistoryDatabase, webRoot: String,
    viewers: ViewerService = ViewerService(), budget: ConnectionBudget = ConnectionBudget(),
    queryLimits: QueryLimits = QueryLimits()
  ) {
    self.queryLimits = queryLimits
    self.budget = budget
    self.viewers = viewers
    self.auth = auth
    self.metrics = metrics
    self.history = history
    self.webRoot = webRoot
  }
  public func start(
    host: String = "127.0.0.1", port: Int = 8765, certificate: String? = nil,
    privateKey: String? = nil, allowPortFallback: Bool = true, beforeBind: (@Sendable () -> Void)? = nil
  ) throws -> Int {
    var ssl: NIOSSLContext?
    if let certificate, let privateKey {
      var config = TLSConfiguration.makeServerConfiguration(
        certificateChain: try NIOSSLCertificate.fromPEMFile(certificate).map { .certificate($0) },
        privateKey: .privateKey(try NIOSSLPrivateKey(file: privateKey, format: .pem)))
      config.minimumTLSVersion = .tlsv12
      config.shutdownTimeout = .seconds(1)
      ssl = try NIOSSLContext(configuration: config)
    }
    beforeBind?()
    let tls = ssl
    let server = self
    func bindPort(_ requested: Int) throws -> any Channel {
      try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .childChannelOption(
          ChannelOptions.writeBufferWaterMark,
          value: ChannelOptions.Types.WriteBufferWaterMark(low: 32768, high: 65536)
        )
        .childChannelInitializer { channel in
          let accepted = server.budget.acquire(tls: tls != nil)
          guard accepted else { return channel.close() }
          let clientId = ObjectIdentifier(channel)
          server.clients.withLock { $0[clientId] = channel }
          let pending = Locked(tls != nil)
          if tls != nil {
            channel.eventLoop.scheduleTask(in: .seconds(5)) {
              if pending.withLock({ $0 }) { channel.close(promise: nil) }
            }
          }
          channel.closeFuture.whenComplete { _ in
            _ = server.clients.withLock { $0.removeValue(forKey: clientId) }
            server.budget.release(handshakePending: pending.withLock { $0 })
          }
          do {
            if let tls {
              try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
            }
          } catch { return channel.eventLoop.makeFailedFuture(error) }
          return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
            .flatMapThrowing {
              let actualPort = channel.localAddress?.port ?? requested
              try channel.pipeline.syncOperations.addHandler(
                RequestHandler(
                  server: server,
                  policy: OriginPolicy(host: host, port: actualPort, tls: tls != nil),
                  handshakePending: pending))
            }
        }.bind(host: host, port: requested).wait()
    }
    let channel: any Channel
    do { channel = try bindPort(port) } catch {
      if port == 0 || !allowPortFallback {
        if let io = error as? IOError, io.errnoCode == EADDRINUSE {
          throw APIError(409, "portInUse")
        }
        throw error
      }
      channel = try bindPort(0)
    }
    channels.withLock { $0.append(channel) }
    return channel.localAddress!.port!
  }
  public func stopListeners() {
    let list = channels.withLock { value in
      let copy = value
      value.removeAll()
      return copy
    }
    for channel in list { try? channel.close().wait() }
    let closing = clients.withLock { Array($0.values) }.map { $0.close() }
    // Start all closes together: TLS peers must not multiply the shutdown deadline.
    for future in closing { try? future.wait() }
  }
  public func shutdown() {
    stopListeners()
    try? group.syncShutdownGracefully()
  }
  public func session(_ r: WebRequest, lan: Bool) throws -> AccountSession {
    try auth.session(
      token: r.cookies[lan ? "cmm_lan_session" : "cmm_session"],
      lan: lan)
  }
  public func route(_ r: WebRequest, policy: OriginPolicy) async throws -> WebResponse {
    let publicRoute =
      r.path == "/healthz" || r.path == "/api/v1/auth/status" || !r.path.hasPrefix("/api/")
    try policy.validate(
      method: r.method, host: r.headers["host"] ?? [], origin: r.headers["origin"] ?? [],
      fetchSite: r.header("sec-fetch-site"), protected: !publicRoute)
    let lan = policy.tls
    let cookieName = lan ? "cmm_lan_session" : "cmm_session"
    func cookie(_ name: String, _ token: String, _ seconds: Int) -> (String, String) {
      (
        "set-cookie",
        "\(name)=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(seconds)\(lan ? "; Secure" : "")"
      )
    }
    if !["GET", "HEAD"].contains(r.method),
      r.header("content-type")?.split(separator: ";").first != "application/json"
    {
      throw APIError(415, "jsonRequired")
    }
    if r.method == "GET" || r.method == "HEAD" {
      switch r.path {
      case "/healthz": return try .json(.object(["status": .string("ok")]))
      case "/api/v1/auth/status":
        let status: String
        if auth.store.recoveryRequired {
          status = "recoveryRequired"
        } else if (try auth.store.account()) == nil {
          status = lan ? "returnToMac" : "setupRequired"
        } else if (try? session(r, lan: lan)) != nil {
          status = "authenticated"
        } else {
          status = "loginRequired"
        }
        return try .json(.object(["status": .string(status)]))
      default: break
      }
      if !r.path.hasPrefix("/api/") { return try staticFile(r.path, head: r.method == "HEAD") }
    }
    if r.method == "POST" {
      switch r.path {
      case "/api/v1/auth/setup":
        guard !lan else { throw APIError(403, "loopbackRequired") }
        let result = try await auth.setup(
          ticket: r.body["setupTicket"].string ?? "", username: r.body["username"].string ?? "",
          password: r.body["password"].string ?? "", ip: r.ip,
          localFirstRun: (r.body["setupTicket"].string ?? "").isEmpty)
        return try .json(
          .object(["csrfToken": .string(result.csrf), "expiresAt": .date(result.expiresAt)]),
          status: 201, headers: [cookie(cookieName, result.token, 43200)])
      case "/api/v1/auth/login":
        let result = try await auth.login(
          username: r.body["username"].string ?? "", password: r.body["password"].string ?? "",
          ip: r.ip, lan: lan)
        return try .json(
          .object(["csrfToken": .string(result.csrf), "expiresAt": .date(result.expiresAt)]),
          headers: [cookie(cookieName, result.token, 43200)])
      default: break
      }
    }
    let session = try session(r, lan: lan)
    if r.path.contains("/apps") || r.path.contains("/history/") || r.path.contains("/recent/") {
      try queryLimits.accept(session: session.hash)
    }
    if !["GET", "HEAD"].contains(r.method) {
      try auth.validateCSRF(r.header("x-csrf-token"), session: session)
    }
    if r.method == "POST", r.path == "/api/v1/auth/logout" {
      auth.logout(token: r.cookies[cookieName])
      return try .json(.null, status: 204, headers: [cookie(cookieName, "", 0)])
    }
    if r.path == "/api/v1/viewers", r.method == "POST" {
      return try .json(
        viewers.create(session: session, channels: r.body["channels"].array.compactMap(\.string)),
        status: 201)
    }
    if r.path.hasPrefix("/api/v1/viewers/") {
      let id = String(r.path.dropFirst("/api/v1/viewers/".count))
      if r.method == "DELETE" {
        try viewers.delete(id, session: session)
        return try .json(.null, status: 204)
      }
      if r.method == "PATCH" {
        return try .json(
          viewers.update(
            id, session: session, visible: r.body["visible"].bool ?? false,
            channels: r.body["channels"].array.compactMap(\.string)))
      }
    }
    guard r.method == "GET" else { throw APIError(404, "notFound") }
    switch r.path {
    case "/api/v1/auth/session":
      return try .json(
        .object([
          "csrfToken": .string(try auth.csrf(for: session)), "expiresAt": .date(session.expiresAt),
        ]))
    case "/api/v1/capabilities": return try .json(metrics.capabilities)
    case "/api/v1/snapshot": return try .json(metrics.snapshot)
    case "/api/v1/apps":
      return try .json(
        metrics.apps(
          sort: r.query["sort"] ?? "cpu", limit: Int(r.query["limit"] ?? "20") ?? 0,
          cursor: r.query["cursor"], query: r.query["q"] ?? "", sequence: r.query["scanSequence"]))
    case "/api/v1/history/status": return try .json(history.status())
    case "/api/v1/history/system", "/api/v1/recent/system":
      let from = Self.timestamp(r.query["from"])
      let to = Self.timestamp(r.query["to"])
      guard let from, let to else { throw APIError(400, "invalidParameter") }
      if r.path.contains("/recent/") && to - from > 300 { throw APIError(400, "invalidParameter") }
      return try .json(
        try await history.query(
          series: (r.query["seriesIds"] ?? "cpu.total").split(separator: ",").map(String.init),
          from: from, to: to, maxPoints: Int(r.query["maxPoints"] ?? "300") ?? 0))
    case "/api/v1/history/apps", "/api/v1/recent/apps":
      guard let from = Self.timestamp(r.query["from"]), let to = Self.timestamp(r.query["to"])
      else { throw APIError(400, "invalidParameter") }
      return try .json(
        try await history.queryApps(
          from: from, to: to, limit: Int(r.query["limit"] ?? "20") ?? 0, cursor: r.query["cursor"],
          sort: r.query["sort"] ?? "cpu", recentOnly: r.path.contains("/recent/"), appId: r.query["appId"]))
    case "/api/v1/events":
      let id = r.query["viewerId"] ?? ""
      try viewers.open(id, session: session)
      return WebResponse(
        status: 200, body: Data(), contentType: "text/event-stream", headers: [], streamViewer: id)
    default:
      if r.path.hasPrefix("/api/v1/apps/"), r.path.hasSuffix("/processes") {
        let id = String(r.path.dropFirst("/api/v1/apps/".count).dropLast("/processes".count))
        return try .json(
          metrics.apps(
            sort: "cpu", limit: 100, cursor: r.query["cursor"], query: "", sequence: nil,
            members: id))
      }
      throw APIError(404, "notFound")
    }
  }
  private static func timestamp(_ text: String?) -> Double? {
    guard let text else { return nil }
    if let n = Double(text), n.isFinite { return n }
    return ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970
  }
  private func staticFile(_ path: String, head: Bool) throws -> WebResponse {
    guard let decoded = path.removingPercentEncoding, !decoded.contains(".."),
      !decoded.contains("\\"), !decoded.contains("\0")
    else { throw APIError(404, "notFound") }
    let relative = decoded == "/" ? "index.html" : String(decoded.dropFirst())
    var file = URL(fileURLWithPath: webRoot).appendingPathComponent(relative)
    if !FileManager.default.fileExists(atPath: file.path), !relative.contains(".") {
      file = URL(fileURLWithPath: webRoot).appendingPathComponent("index.html")
    }
    let root = URL(fileURLWithPath: webRoot).resolvingSymlinksInPath().path + "/"
    guard file.resolvingSymlinksInPath().path.hasPrefix(root),
      let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
      size.intValue <= 2 * 1024 * 1024, let data = try? Data(contentsOf: file)
    else { throw APIError(404, "notFound") }
    let type =
      [
        "html": "text/html; charset=utf-8", "js": "application/javascript", "css": "text/css",
        "json": "application/json", "svg": "image/svg+xml", "png": "image/png",
      ][file.pathExtension] ?? "application/octet-stream"
    return WebResponse(
      status: 200, body: head ? Data() : data, contentType: type, headers: [], streamViewer: nil)
  }
}

private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  private let server: MonitorHTTPServer, policy: OriginPolicy
  private let handshakePending: Locked<Bool>
  private var head: HTTPRequestHead?, bytes = Data(), busy = false
  private var timeout: Scheduled<Void>?, stream: RepeatedTask?, viewer: String?
  private var streamPending = false, lastApps = "", lastSystem = ""
  init(server: MonitorHTTPServer, policy: OriginPolicy, handshakePending: Locked<Bool>) {
    self.server = server
    self.policy = policy
    self.handshakePending = handshakePending
  }
  func channelActive(context: ChannelHandlerContext) {
    let channel = context.channel
    timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
    context.fireChannelActive()
  }
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let event = event as? TLSUserEvent, case .handshakeCompleted = event {
      let wasPending = handshakePending.withLock { value in
        let old = value
        value = false
        return old
      }
      if wasPending { server.budget.handshakeDone() }
    }
    context.fireUserInboundEventTriggered(event)
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      guard !busy, self.head == nil,
        head.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 8192,
        head.uri.utf8.count <= 4096
      else {
        context.close(promise: nil)
        return
      }
      self.head = head
    case .body(var buffer):
      guard bytes.count + buffer.readableBytes <= 16384 else {
        context.close(promise: nil)
        return
      }
      if let data = buffer.readBytes(length: buffer.readableBytes) {
        bytes.append(contentsOf: data)
      }
    case .end:
      guard let head else {
        context.close(promise: nil)
        return
      }
      busy = true
      let request: WebRequest
      do {
        let body =
          bytes.isEmpty
          ? JSONValue.object([:]) : try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard let components = URLComponents(string: "http://local" + head.uri),
          components.path.hasPrefix("/")
        else { throw APIError(400, "invalidRequest") }
        let query = Dictionary(
          (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
          uniquingKeysWith: { a, _ in a })
        var headers: [String: [String]] = [:]
        for header in head.headers {
          headers[header.name.lowercased(), default: []].append(header.value)
        }
        request = WebRequest(
          method: head.method.rawValue, path: components.path, query: query, headers: headers,
          body: body, ip: context.channel.remoteAddress?.ipAddress ?? "unknown")
      } catch {
        respond(
          context.channel, response: try! .json(APIError(400, "invalidRequest").json, status: 400))
        return
      }
      let channel = context.channel
      let server = self.server
      let policy = self.policy
      let handler = self
      Task {
        do {
          let response = try await server.route(request, policy: policy)
          channel.eventLoop.execute {
            handler.respond(channel, response: response, request: request)
          }
        } catch {
          let e = (error as? APIError) ?? APIError(503, "serviceUnavailable")
          let response = try! WebResponse.json(e.json, status: e.status)
          channel.eventLoop.execute { handler.respond(channel, response: response) }
        }
      }
    }
  }
  private func respond(_ channel: any Channel, response: WebResponse, request: WebRequest? = nil) {
    guard channel.isActive else {
      if let id = response.streamViewer { server.viewers.close(id) }
      return
    }
    timeout?.cancel()
    var headers = HTTPHeaders([
      ("content-type", response.contentType), ("cache-control", "no-store"),
      ("x-content-type-options", "nosniff"), ("x-frame-options", "DENY"),
      (
        "content-security-policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      ),
    ])
    for (name, value) in response.headers { headers.add(name: name, value: value) }
    if let id = response.streamViewer, let request {
      viewer = id
      headers.add(name: "transfer-encoding", value: "chunked")
      channel.write(
        HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: headers)),
        promise: nil)
      stream = channel.eventLoop.scheduleRepeatedTask(
        initialDelay: .milliseconds(0), delay: .seconds(1)
      ) { [self] task in
        guard let session = try? server.session(request, lan: policy.tls),
          let channels = server.viewers.active(id, session: session)
        else {
          task.cancel()
          server.viewers.close(id)
          channel.close(promise: nil)
          return
        }
        guard !streamPending, channel.isWritable else {
          task.cancel()
          server.viewers.close(id)
          channel.close(promise: nil)
          return
        }
        var message = ": heartbeat\n\n"
        if channels.contains("system") || channels.contains("temperature")
          || channels.contains("gpu")
        {
          let key = server.metrics.sampleSequence
          if key != lastSystem {
            lastSystem = key
            if let json = String(data: server.metrics.encodedSnapshot, encoding: .utf8) {
              message += "event: system\ndata: \(json)\n\n"
            }
          }
        }
        if channels.contains("apps") {
          let key = server.metrics.appSequence
          if key != lastApps {
            lastApps = key
            if server.metrics.encodedAppNotification.count <= 2048,
              let json = String(data: server.metrics.encodedAppNotification, encoding: .utf8)
            {
              message += "event: apps\ndata: \(json)\n\n"
            }
          }
        }
        guard message.utf8.count <= 128 * 1024 else {
          channel.close(promise: nil)
          return
        }
        var buffer = channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        streamPending = true
        channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).whenComplete {
          [self] _ in streamPending = false
        }
      }
    } else {
      headers.add(
        name: "content-length", value: String(response.status == 204 ? 0 : response.body.count))
      headers.add(name: "connection", value: "close")
      channel.write(
        HTTPServerResponsePart.head(
          .init(
            version: .http1_1, status: HTTPResponseStatus(statusCode: response.status),
            headers: headers)), promise: nil)
      if response.status != 204 {
        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
      }
      channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
        channel.close(promise: nil)
      }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    timeout?.cancel()
    stream?.cancel()
    if let viewer { server.viewers.close(viewer) }
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
