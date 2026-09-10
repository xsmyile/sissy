import Foundation
import NIOCore
import NIOWebSocket

/// Decoded form of a control message from the app. Closed set; unknown keys
/// are ignored by `JSONDecoder` and missing optionals decode to nil.
private struct ClientMessage: Decodable {
    let type: String
    let primaryMetric: String?
    let claudeLimits: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case claudeLimits = "claude_limits"
        case primaryMetric = "primary_metric"
    }
}

/// Per-connection WebSocket handler that also acts as a `FrameSink`. Two
/// isolation domains touch the same state: NIO's channel event loop
/// (`handlerAdded`, `channelRead`, `heartbeatTick`, `channelInactive`,
/// `errorCaught`) and the async `Hub.broadcast` TaskGroup (`deliver`,
/// `close`). The class itself is plain `Sendable`; all mutable state is
/// pushed into a nested `@unchecked Sendable State` whose access is
/// serialized through an `NSLock`. `Channel` is `Sendable` in NIO 2;
/// cross-thread `writeAndFlush` / `close` invocations re-schedule onto the
/// channel's event loop internally.
final class WebSocketSinkHandler: ChannelInboundHandler, FrameSink, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let hub: Hub
    private let server: SissyServer

    // Liveness tracking. Without these, a client killed outright (or whose
    // socket drops without a clean close) leaves the daemon socket "alive"
    // until either the next write fails through TCP retransmit timeouts
    // (minutes) or the kernel's idle keepalive fires (2 hours on macOS
    // default), and `/stats` keeps counting a client that is gone.
    //
    // Mitigation: send our own WS ping on a fixed cadence and treat lack
    // of any inbound traffic for `heartbeatTimeout` as a dead peer. Closing
    // the channel fires `channelInactive` -> existing presence rebroadcast
    // path, so the count drops within `heartbeatTimeout` of the peer
    // going away.
    //
    // SignalR-equivalent defaults: ping every 15 s, declare dead at 30 s of
    // silence. RFC 6455 leaves the cadence to the application. URLSession
    // answers our ping with a pong on the app's behalf and `channelRead`
    // refreshes `lastInboundAt` for any inbound frame, so a healthy but
    // idle app stays well inside the timeout window.
    private static let heartbeatInterval: TimeAmount = .seconds(15)
    private static let heartbeatTimeout: TimeAmount = .seconds(30)

    /// Locked mutable state. Held by reference so `final class
    /// WebSocketSinkHandler` can stay Sendable without `@unchecked`.
    /// Reads are cheap (uncontended in steady state — event loop and Hub
    /// TaskGroup converge for a brief moment per broadcast).
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var channel: (any Channel)?
        var registered = false
        var heartbeatTask: RepeatedTask?
        var lastInboundAt: NIODeadline = .now()
    }
    private let state = State()

    init(hub: Hub, server: SissyServer) {
        self.hub = hub
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let loop = context.eventLoop
        let alreadyRegistered: Bool = state.lock.withLock {
            if state.registered { return true }
            state.channel = context.channel
            state.registered = true
            state.lastInboundAt = .now()
            state.heartbeatTask = loop.scheduleRepeatedTask(
                initialDelay: Self.heartbeatInterval,
                delay: Self.heartbeatInterval
            ) { [weak self] _ in
                self?.heartbeatTick()
            }
            return false
        }
        if alreadyRegistered { return }
        let me: any FrameSink = self
        let hub = self.hub
        Task { await hub.register(me) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        unregister()
    }

    func channelInactive(context: ChannelHandlerContext) {
        unregister()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
        unregister()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Refresh the liveness marker. Touched here, in `handlerAdded`, and
        // in `heartbeatTick` (all on the event loop) but goes through the
        // shared lock so a concurrent `deliver` from the Hub TaskGroup
        // can't see a torn value.
        state.lock.withLock { state.lastInboundAt = .now() }
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            var payload = frame.unmaskedData
            let pong = WebSocketFrame(
                fin: true,
                opcode: .pong,
                data: payload.readSlice(length: payload.readableBytes) ?? frame.unmaskedData
            )
            context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)
        case .text:
            var buf = frame.unmaskedData
            let bytes = buf.readBytes(length: buf.readableBytes) ?? []
            handleClientMessage(Data(bytes))
        case .binary:
            break
        default:
            break
        }
    }

    private func handleClientMessage(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(ClientMessage.self, from: data) else { return }
        switch msg.type {
        case "hello":
            if let metric = msg.primaryMetric {
                let server = self.server
                Task { await server.setPrimaryMetric(metric) }
            }
            if let claudeLimits = msg.claudeLimits {
                let server = self.server
                Task { await server.setClaudeLimits(enabled: claudeLimits) }
            }
        case "set_claude_limits":
            guard let enabled = msg.claudeLimits else { return }
            let server = self.server
            Task { await server.setClaudeLimits(enabled: enabled) }
        default:
            break
        }
    }

    // MARK: FrameSink

    func deliver(_ payload: Data) async {
        guard let channel = state.lock.withLock({ state.channel }) else { return }
        var buf = channel.allocator.buffer(capacity: payload.count)
        buf.writeBytes(payload)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        try? await channel.writeAndFlush(frame)
    }

    private func unregister() {
        let proceed: Bool = state.lock.withLock {
            if !state.registered { return false }
            state.registered = false
            state.heartbeatTask?.cancel()
            state.heartbeatTask = nil
            state.channel = nil
            return true
        }
        if !proceed { return }
        let me: any FrameSink = self
        let hub = self.hub
        Task { await hub.unregister(me) }
    }

    /// Runs every `heartbeatInterval` on the channel's event loop. Sends a
    /// WS ping frame for the peer to pong; if `heartbeatTimeout` has elapsed
    /// without any inbound traffic, declares the socket dead and closes it.
    /// The close triggers `channelInactive` -> `unregister()`.
    private func heartbeatTick() {
        let snapshot: (channel: (any Channel)?, last: NIODeadline) = state.lock.withLock {
            (state.channel, state.lastInboundAt)
        }
        guard let channel = snapshot.channel else { return }
        let now = NIODeadline.now()
        if now - snapshot.last > Self.heartbeatTimeout {
            channel.close(promise: nil)
            return
        }
        let empty = channel.allocator.buffer(capacity: 0)
        let ping = WebSocketFrame(fin: true, opcode: .ping, data: empty)
        channel.writeAndFlush(ping, promise: nil)
    }
}
