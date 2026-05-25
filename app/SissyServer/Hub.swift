import Foundation

protocol FrameSink: Sendable, AnyObject {
    func deliver(_ payload: Data) async
    func close() async
}

enum SinkKind: Sendable {
    case unknown
    case app
    case device
}

actor Hub {
    private var sinks: [ObjectIdentifier: any FrameSink] = [:]
    private var kinds: [ObjectIdentifier: SinkKind] = [:]
    private var lastFramePayload: Data?
    private var lastFrameAt: Date?
    private(set) var lastFrame: FrameData?

    func register(_ sink: any FrameSink) async {
        let id = ObjectIdentifier(sink)
        sinks[id] = sink
        kinds[id] = .unknown
        if let payload = lastFramePayload {
            await sink.deliver(payload)
        }
    }

    func unregister(_ sink: any FrameSink) {
        let id = ObjectIdentifier(sink)
        sinks.removeValue(forKey: id)
        kinds.removeValue(forKey: id)
    }

    func setKind(_ sink: any FrameSink, kind: SinkKind) {
        let id = ObjectIdentifier(sink)
        guard sinks[id] != nil else { return }
        kinds[id] = kind
    }

    func hasDevice() -> Bool {
        kinds.values.contains(where: { $0 == .device })
    }

    func broadcast(_ frame: FrameData) async {
        lastFrameAt = Date()
        let payload = encode(frame, devicePresent: hasDevice())
        // Cache a milestone-stripped copy for replays (new sink connect via
        // `register`, device-presence flip via `rebroadcastPresence`, app
        // process restart). The live broadcast below is the authoritative
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
                milestone: nil
            )
            lastFrame = cached
            lastFramePayload = encode(cached, devicePresent: hasDevice())
        }
        // Fire deliveries concurrently. A slow sink (firmware over WiFi)
        // used to serialize the fast sink (app over localhost) behind it,
        // so the menubar icon could lag tens-to-hundreds of milliseconds
        // for no reason other than dictionary iteration order. TaskGroup
        // gives each sink its own awaitable Task and joins on group exit.
        let snapshot = Array(sinks.values)
        await withTaskGroup(of: Void.self) { group in
            for sink in snapshot {
                group.addTask { await sink.deliver(payload) }
            }
        }
    }

    /// Re-emit the cached last frame with a refreshed `device_present` flag.
    /// Used after a sink's kind is resolved post-hello or after a sink
    /// disconnects, so the menubar header flips immediately instead of
    /// waiting for the next usage poll to fire a new frame.
    func rebroadcastPresence() async {
        guard let frame = lastFrame else { return }
        let payload = encode(frame, devicePresent: hasDevice())
        lastFramePayload = payload
        let snapshot = Array(sinks.values)
        await withTaskGroup(of: Void.self) { group in
            for sink in snapshot {
                group.addTask { await sink.deliver(payload) }
            }
        }
    }

    func connectedCount() -> Int { sinks.count }
    func lastFrameTimestamp() -> Date? { lastFrameAt }

    private func encode(_ frame: FrameData, devicePresent: Bool) -> Data {
        var dict: [String: Any] = [
            "type": "frame",
            "tokens": frame.tokens,
            "cost": frame.cost,
            "burn": frame.burn,
            "state": frame.state,
            "primary": frame.primary,
            "primary_label": frame.primaryLabel,
            "device_present": devicePresent,
            "ts": Int(Date().timeIntervalSince1970),
        ]
        // Emit the field only when set so a sink that doesn't care (firmware)
        // never sees an extra key with `null`. Same wire weight as before on
        // the steady-state frames, which is most of them.
        if let milestone = frame.milestone {
            dict["milestone"] = milestone
        }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
}
