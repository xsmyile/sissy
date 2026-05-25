import Foundation
import NIOCore
import NIOWebSocket

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

    // Liveness tracking. Without these, a firmware client whose power gets
    // yanked (or whose WiFi drops without a clean close) leaves the daemon
    // socket "alive" until either the next write fails through TCP
    // retransmit timeouts (minutes) or the kernel's idle keepalive fires
    // (2 hours on macOS default). The menubar header keeps reporting
    // "Sissy is …" with stale state in the meantime.
    //
    // Mitigation: send our own WS ping on a fixed cadence and treat lack
    // of any inbound traffic for `heartbeatTimeout` as a dead peer. Closing
    // the channel fires `channelInactive` -> existing presence rebroadcast
    // path, so the UI flips within `heartbeatTimeout` of the unplug.
    //
    // SignalR-equivalent defaults: ping every 15 s, declare dead at 30 s of
    // silence. Industry-standard for low-latency realtime UI fleets;
    // RFC 6455 leaves the cadence to the application. The firmware already
    // pings the daemon every 15 s (`WsClient.cpp` `enableHeartbeat`), so
    // inbound traffic refreshes `lastInboundAt` well inside the timeout
    // window during normal operation.
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
        unregister(rebroadcastAfter: true)
    }

    func channelInactive(context: ChannelHandlerContext) {
        unregister(rebroadcastAfter: true)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
        unregister(rebroadcastAfter: true)
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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return }
        switch type {
        case "hello":
            if let metric = obj["primary_metric"] as? String {
                let server = self.server
                Task { await server.setPrimaryMetric(metric) }
            }
            if let freq = obj["milestone_frequency"] as? String {
                let server = self.server
                Task { await server.setMilestoneFrequency(freq) }
            }
            // Tag this sink as app vs device so the Hub can flip
            // `device_present` in broadcast frames. Mac app sends
            // `client: "mac-app"`; firmware sends `device`/`fw` and no
            // `client` key. Default unknown → device covers any future
            // hardware client without a code change.
            let kind: SinkKind
            if let client = obj["client"] as? String, client == "mac-app" {
                kind = .app
            } else {
                kind = .device
            }
            let me: any FrameSink = self
            let hub = self.hub
            Task {
                await hub.setKind(me, kind: kind)
                await hub.rebroadcastPresence()
            }
        case "set_state":
            // `state` absent or "auto" → clear pin and resume computed state.
            let raw = obj["state"] as? String
            let server = self.server
            Task { await server.setPinnedState(raw) }
        case "set_milestone_frequency":
            // Invalid keys (typos, future values) are dropped by the actor's
            // `MilestoneFrequency.isValid` guard; no error path needed here.
            guard let raw = obj["value"] as? String else { return }
            let server = self.server
            Task { await server.setMilestoneFrequency(raw) }
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

    func close() async {
        let channel = state.lock.withLock { state.channel }
        try? await channel?.close()
    }

    private func unregister(rebroadcastAfter: Bool = false) {
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
        Task {
            await hub.unregister(me)
            if rebroadcastAfter {
                await hub.rebroadcastPresence()
            }
        }
    }

    /// Runs every `heartbeatInterval` on the channel's event loop. Sends a
    /// WS ping frame for the peer to pong; if `heartbeatTimeout` has elapsed
    /// without any inbound traffic, declares the socket dead and closes it.
    /// The close triggers `channelInactive` -> `unregister(rebroadcastAfter:)`
    /// which is what actually flips `device_present` for the menubar.
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
