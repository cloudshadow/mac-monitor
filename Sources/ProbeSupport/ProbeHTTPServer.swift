import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// Feasibility-only listener: no monitoring routes and no unauthenticated metrics.
public final class ProbeHTTPServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channels: [any Channel] = []
    public init() {}
    public func start(port: Int = 0, certificate: String? = nil, privateKey: String? = nil) throws -> Int {
        var context: NIOSSLContext?
        if let certificate, let privateKey {
            var config = TLSConfiguration.makeServerConfiguration(
                certificateChain: try NIOSSLCertificate.fromPEMFile(certificate).map { .certificate($0) },
                privateKey: .privateKey(try NIOSSLPrivateKey(file: privateKey, format: .pem)))
            config.minimumTLSVersion = .tlsv12
            context = try NIOSSLContext(configuration: config)
        } else if certificate != nil || privateKey != nil {
            throw ProbeError.invalidArguments("TLS requires both --certificate and --private-key")
        }
        let tls = context
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                if let tls {
                    do { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    catch { return channel.eventLoop.makeFailedFuture(error) }
                }
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(ProbeHealthHandler())
                }
            }
            .bind(host: "127.0.0.1", port: port).wait()
        channels.append(channel)
        return channel.localAddress!.port!
    }
    public func close() throws {
        for channel in channels { try channel.close().wait() }
        channels.removeAll()
        try group.syncShutdownGracefully()
    }
}

private final class ProbeHealthHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var request: HTTPRequestHead?
    private var bodyBytes = 0
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): request = head; bodyBytes = 0
        case .body(let buffer):
            bodyBytes += buffer.readableBytes
            if bodyBytes > 16_384 { context.close(promise: nil) }
        case .end:
            guard let request else { context.close(promise: nil); return }
            let ok = request.method == .GET && request.uri == "/healthz"
            let body = ok ? "{\"status\":\"ok\"}" : "{\"error\":{\"code\":\"notImplemented\"}}"
            let headers = HTTPHeaders([("content-type", "application/json"), ("content-length", String(body.utf8.count)),
                                       ("cache-control", "no-store"), ("x-content-type-options", "nosniff"), ("connection", "close")])
            context.write(wrapOutboundOut(.head(.init(version: request.version, status: ok ? .ok : .notFound, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
            self.request = nil
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

public enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String), database(String), cryptoUnavailable
    public var description: String {
        switch self {
        case .invalidArguments(let message), .database(let message): return message
        case .cryptoUnavailable: return "libsodium initialization failed"
        }
    }
}
