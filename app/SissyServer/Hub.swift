import Foundation

protocol FrameSink: Sendable, AnyObject {
    func deliver(_ payload: Data) async
}

actor Hub {
    private var sinks: [ObjectIdentifier: any FrameSink] = [:]
    private var lastFramePayload: Data?
    private var lastFrameAt: Date?
    private(set) var lastFrame: FrameData?
    private var presenceChanged: (@Sendable (Bool) async -> Void)?

    /// Called when the first client arrives and when the last one leaves, so
    /// the daemon can drive what only makes sense while someone is listening.
    ///
    /// Edges only: a second connection is not a second arrival, and the app
    /// reconnecting through a backoff is one departure and one arrival rather
    /// than a stream of them.
    func onPresenceChange(_ handler: @escaping @Sendable (Bool) async -> Void) {
        presenceChanged = handler
    }

    /// The handler runs *before* the replay, and the sink is already in
    /// `sinks` when it does: a handler that rebroadcasts therefore refreshes
    /// `lastFramePayload` in time for this client to be replayed the new
    /// frame instead of the stale one it would otherwise render first.
    func register(_ sink: any FrameSink) async {
        let id = ObjectIdentifier(sink)
        let wasEmpty = sinks.isEmpty
        sinks[id] = sink
        if wasEmpty {
            await presenceChanged?(true)
        }
        if let payload = lastFramePayload {
            await sink.deliver(payload)
        }
    }

    func unregister(_ sink: any FrameSink) async {
        let id = ObjectIdentifier(sink)
        guard sinks.removeValue(forKey: id) != nil, sinks.isEmpty else { return }
        await presenceChanged?(false)
    }

    func broadcast(_ frame: FrameData) async {
        lastFrameAt = Date()
        let payload = encode(frame)
        lastFrame = frame
        lastFramePayload = payload
        // Fire deliveries concurrently rather than in dictionary iteration
        // order, so one slow sink cannot hold up the rest.
        let snapshot = Array(sinks.values)
        await withTaskGroup(of: Void.self) { group in
            for sink in snapshot {
                group.addTask { await sink.deliver(payload) }
            }
        }
    }

    func connectedCount() -> Int { sinks.count }
    func lastFrameTimestamp() -> Date? { lastFrameAt }

    private func encode(_ frame: FrameData) -> Data {
        // Per-provider slices land on the wire as raw `{id, tokens, cost}`
        // dicts; cost goes through `NSDecimalNumber.stringValue` so the app
        // can `Decimal(string:)` it back lossless. Always emitted, even when
        // empty, so a fallback-using client can distinguish "no providers
        // yet" from "field absent on an older daemon".
        let providers: [[String: Any]] = frame.providers.map { slice in
            var row: [String: Any] = [
                "id": slice.id,
                "tokens": slice.tokens,
                "cost": NSDecimalNumber(decimal: slice.cost).stringValue,
                "windows": slice.windows.map { window in
                    [
                        "minutes": window.minutes,
                        "used_percent": window.usedPercent,
                        "resets_at": Int(window.resetsAt.timeIntervalSince1970),
                    ] as [String: Any]
                },
            ]
            // Absent rather than null for a provider that names no plan, same
            // rule the `prev_*` pair below follows. The tier rides inside the
            // plan's branch: on its own it names nothing the app could place.
            if let plan = slice.plan {
                row["plan"] = plan
                if let tier = slice.planTier { row["plan_tier"] = tier }
            }
            return row
        }
        var dict: [String: Any] = [
            "type": "frame",
            "tokens": frame.tokens,
            "cost": frame.cost,
            "burn": frame.burn,
            "primary": frame.primary,
            "primary_label": frame.primaryLabel,
            "ts": Int(Date().timeIntervalSince1970),
            "providers": providers,
            // Always present, unlike the pairs below: the app draws the
            // control from this, and an absent key could not be told apart
            // from a daemon that predates the feature.
            "keep_awake": [
                "mode": frame.keepAwake.mode.rawValue,
                "active": frame.keepAwake.active,
            ] as [String: Any],
        ]
        // Emit the field only when set so the app reads an absent key rather
        // than a `null` it has to special-case. Steady-state frames — most of
        // them — keep the same wire weight as before.
        if let prevTokens = frame.prevTokens, let prevCost = frame.prevCost {
            dict["prev_tokens"] = prevTokens
            dict["prev_cost"] = NSDecimalNumber(decimal: prevCost).stringValue
        }
        do {
            return try JSONSerialization.data(withJSONObject: dict)
        } catch {
            daemonLog("sissy-serverd: frame encode failed at \(frame.tokens) tokens: \(error)")
            return Data()
        }
    }
}
