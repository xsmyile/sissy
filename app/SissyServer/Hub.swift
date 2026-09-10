import Foundation

protocol FrameSink: Sendable, AnyObject {
    func deliver(_ payload: Data) async
}

actor Hub {
    private var sinks: [ObjectIdentifier: any FrameSink] = [:]
    private var lastFramePayload: Data?
    private var lastFrameAt: Date?
    private(set) var lastFrame: FrameData?

    func register(_ sink: any FrameSink) async {
        let id = ObjectIdentifier(sink)
        sinks[id] = sink
        if let payload = lastFramePayload {
            await sink.deliver(payload)
        }
    }

    func unregister(_ sink: any FrameSink) {
        let id = ObjectIdentifier(sink)
        sinks.removeValue(forKey: id)
    }

    func broadcast(_ frame: FrameData) async {
        lastFrameAt = Date()
        let payload = encode(frame)
        // Cache a milestone-stripped copy for replays (new sink connect via
        // `register`, app process restart). The live broadcast below is the
        // authoritative
        // delivery for that crossing — replaying the same milestone string
        // later would refire the celebration pop-up for an already-seen
        // event. Steady-state frames (milestone == nil) skip the extra
        // encode.
        if frame.milestone == nil {
            lastFrame = frame
            lastFramePayload = payload
        } else {
            let cached = FrameData(
                tokens: frame.tokens,
                cost: frame.cost,
                burn: frame.burn,
                state: frame.state,
                primary: frame.primary,
                primaryLabel: frame.primaryLabel,
                milestone: nil,
                providers: frame.providers,
                prevTokens: frame.prevTokens,
                prevCost: frame.prevCost
            )
            lastFrame = cached
            lastFramePayload = encode(cached)
        }
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
            [
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
        }
        var dict: [String: Any] = [
            "type": "frame",
            "tokens": frame.tokens,
            "cost": frame.cost,
            "burn": frame.burn,
            "state": frame.state,
            "primary": frame.primary,
            "primary_label": frame.primaryLabel,
            "ts": Int(Date().timeIntervalSince1970),
            "providers": providers,
        ]
        // Emit the field only when set so a sink that doesn't care (firmware)
        // never sees an extra key with `null`. Same wire weight as before on
        // the steady-state frames, which is most of them.
        if let milestone = frame.milestone {
            dict["milestone"] = milestone
        }
        if let prevTokens = frame.prevTokens, let prevCost = frame.prevCost {
            dict["prev_tokens"] = prevTokens
            dict["prev_cost"] = NSDecimalNumber(decimal: prevCost).stringValue
        }
        do {
            return try JSONSerialization.data(withJSONObject: dict)
        } catch {
            daemonLog("sissy-serverd: frame encode failed for state \(frame.state): \(error)")
            return Data()
        }
    }
}
