import Foundation
import NIOCore
import NIOHTTP1

final class HTTPRequestHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let expectedToken: String
    private let healthSnapshot: @Sendable () async -> HealthResponse
    private let statsSnapshot: @Sendable () async -> StatsResponse

    init(
        expectedToken: String,
        healthSnapshot: @escaping @Sendable () async -> HealthResponse,
        statsSnapshot: @escaping @Sendable () async -> StatsResponse
    ) {
        self.expectedToken = expectedToken
        self.healthSnapshot = healthSnapshot
        self.statsSnapshot = statsSnapshot
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
            handle(context: context, head: head)
        case .body, .end:
            break
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let token = expectedToken
        let auth = head.headers["authorization"].first
        if !Auth.authorized(headerValue: auth, expected: token) {
            respondError(context: context, status: .unauthorized, message: "unauthorized")
            return
        }

        let snapshotHealth = healthSnapshot
        let snapshotStats = statsSnapshot
        let path = head.uri
        let eventLoop = context.eventLoop
        let ctxBox = NIOLoopBound(context, eventLoop: eventLoop)

        switch path {
        case "/health":
            Task {
                let body = await snapshotHealth()
                eventLoop.execute {
                    Self.respond(context: ctxBox.value, status: .ok, body: body)
                }
            }
        case "/stats":
            Task {
                let body = await snapshotStats()
                eventLoop.execute {
                    Self.respond(context: ctxBox.value, status: .ok, body: body)
                }
            }
        default:
            respondError(context: context, status: .notFound, message: "not found")
        }
    }

    private struct ErrorBody: Codable {
        let error: String
    }

    private func respondError(
        context: ChannelHandlerContext, status: HTTPResponseStatus, message: String
    ) {
        Self.respond(context: context, status: status, body: ErrorBody(error: message))
    }

    private static func respond<Body: Encodable>(
        context: ChannelHandlerContext, status: HTTPResponseStatus, body: Body
    ) {
        let encoder = JSONEncoder()
        let payload = (try? encoder.encode(body)) ?? Data()
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(payload.count))
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        // `whenComplete` is a `@Sendable` closure under Swift 6;
        // `ChannelHandlerContext` isn't Sendable, so bind it through
        // `NIOLoopBound` first. Both writes target the channel that owns
        // this event loop, so the unwrap inside the closure is safe.
        let ctxBox = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            ctxBox.value.close(promise: nil)
        }
    }
}
