import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Puts a `UsageEngine` behind a loopback WebSocket.
///
/// Nothing about metering lives here any more — this is the transport, and
/// the only thing left that needs NIO. The app runs the same engine
/// in-process; see `docs/single-process-migration.md`.
actor SissyServer {
    let hub: Hub
    let engine: UsageEngine

    private let group: EventLoopGroup
    private let host: String
    private let port: Int
    private let authToken: String
    private var channel: (any Channel)?
    private var startedAt: Date = .distantPast
    private let isoFormatter = ISO8601DateFormatter()

    init(
        config: ServerConfig,
        group: EventLoopGroup,
        configURL: URL = ServerConfig.defaultURL
    ) {
        self.group = group
        self.host = config.host
        self.port = config.port
        self.authToken = config.authToken
        self.hub = Hub()
        self.engine = UsageEngine(config: config, configURL: configURL)
    }

    func setPrimaryMetric(_ raw: String) async { await engine.setPrimaryMetric(raw) }
    func setClaudeLimits(enabled: Bool) async { await engine.setClaudeLimits(enabled: enabled) }
    func setKeepAwake(mode raw: String) async { await engine.setKeepAwake(mode: raw) }
    func rebroadcastFromCache() async { await engine.rebroadcastFromCache() }

    func start() async throws {
        startedAt = Date()
        // Registered before the bind, or the first client could arrive
        // between the two and leave the hold waiting for a second one.
        let engine = self.engine
        await hub.onPresenceChange { present in
            await engine.setObserverPresent(present)
        }
        // Bind first so clients can connect immediately. The engine's initial
        // backfill can take several seconds on a multi-MB log tree.
        try await bootstrap()
        let hub = self.hub
        await engine.start { frame in
            await hub.broadcast(frame)
        }
    }

    func stop() async {
        await engine.stop()
        try? await channel?.close().get()
    }

    func healthSnapshot() async -> HealthResponse {
        let readiness = await engine.readiness()
        // Suppress "no-jsonl-found" until the initial cold scan has
        // completed. The server binds before the first enumeration runs, so
        // without this gate the frontend briefly observes zero files and
        // flashes the yellow "No JSONL" warning on every start, even on a
        // tree with hundreds of session files.
        let usageStatus = (readiness.isWarm && readiness.filesWatched == 0) ? "no-jsonl-found" : "ok"
        return HealthResponse(
            status: "ok",
            usageReader: usageStatus,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
        )
    }

    func statsSnapshot() async -> StatsResponse {
        let count = await hub.connectedCount()
        let lastAt = await hub.lastFrameTimestamp()
        let readiness = await engine.readiness()
        return StatsResponse(
            connectedClients: count,
            filesWatched: readiness.filesWatched,
            lastFrameAt: lastAt.map { isoFormatter.string(from: $0) }
        )
    }

    private func bootstrap() async throws {
        let server = self
        let hub = self.hub
        let expectedToken = authToken

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 14,
            shouldUpgrade: { (channel: any Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> in
                let auth = head.headers["authorization"].first
                if !Auth.authorized(headerValue: auth, expected: expectedToken) {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                if head.uri != "/ws" {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: any Channel, _: HTTPRequestHead) -> EventLoopFuture<Void> in
                let handler = WebSocketSinkHandler(hub: hub, server: server)
                return channel.pipeline.addHandler(handler).flatMap {
                    channel.eventLoop.makeSucceededFuture(())
                }
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPRequestHandler(
                    expectedToken: expectedToken,
                    healthSnapshot: { await server.healthSnapshot() },
                    statsSnapshot: { await server.statsSnapshot() }
                )
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
                    .flatMap { channel.pipeline.addHandler(httpHandler) }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Belt-and-suspenders to the application-level WS heartbeat in
            // `WebSocketSinkHandler`. macOS keepidle defaults to ~2 hours so
            // this alone wouldn't catch a dead sink in time, but combining
            // it with the WS ping covers the case where the socket is alive
            // at the kernel level yet stuck before reaching the handler.
            // Cheap to enable.
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)

        channel = try await bootstrap.bind(host: host, port: port).get()
    }
}
