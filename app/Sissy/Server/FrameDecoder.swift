import Foundation

/// Parses the daemon's `frame` messages into the engine's own `FrameData`.
///
/// Lives apart from `WebSocketClient` because the frame shape has no schema
/// shared with `app/SissyServer/Hub.swift` — keeping the parse pure is what
/// lets a test pin the wire contract without a live socket.
enum FrameDecoder {
    /// The frame together with the moment the daemon built it.
    ///
    /// `builtAt` rides beside the frame rather than inside it because it
    /// describes the transport, not the reading: `Hub` replays its cached
    /// payload to every client that connects, and that payload keeps the
    /// timestamp of the emit it came from, so a reconnect to an idle daemon
    /// reports the age of the real last frame instead of the moment the
    /// socket happened to open. nil when the frame carries no usable `ts`,
    /// which leaves the caller to fall back to now.
    struct Decoded: Equatable {
        let frame: FrameData
        let builtAt: Date?
    }

    static func decode(_ text: String) -> Decoded? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> Decoded? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            dict["type"] as? String == "frame"
        else { return nil }

        let tokens = dict["tokens"] as? String ?? placeholder
        let prev = decodePrev(dict)
        let ts = dict["ts"] as? Int ?? 0
        return Decoded(
            frame: FrameData(
                tokens: tokens,
                cost: dict["cost"] as? String ?? placeholder,
                burn: dict["burn"] as? String ?? placeholder,
                primary: dict["primary"] as? String ?? tokens,
                primaryLabel: dict["primary_label"] as? String ?? defaultPrimaryLabel,
                providers: decodeProviders(dict["providers"]),
                prevTokens: prev?.tokens,
                prevCost: prev?.cost,
                keepAwake: decodeKeepAwake(dict["keep_awake"])
            ),
            builtAt: ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil
        )
    }

    static let placeholder = "..."
    private static let defaultPrimaryLabel = "TOKENS"

    private static func decodeProviders(_ raw: Any?) -> [ProviderSlice] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                let tokens = row["tokens"] as? Int,
                let costRaw = row["cost"] as? String,
                let cost = Decimal(string: costRaw)
            else { return nil }
            return ProviderSlice(
                id: id,
                tokens: tokens,
                cost: cost,
                windows: decodeWindows(row["windows"]),
                plan: row["plan"] as? String,
                planTier: row["plan_tier"] as? String
            )
        }
    }

    /// Sorted shortest-window-first so the panel can render the tightest
    /// limit as the row's primary gauge without re-deriving the order.
    private static func decodeWindows(_ raw: Any?) -> [UsageWindow] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return
            rows
            .compactMap { row -> UsageWindow? in
                guard let minutes = row["minutes"] as? Int, minutes > 0,
                    let used = row["used_percent"] as? Double,
                    let resets = row["resets_at"] as? Double
                else { return nil }
                return UsageWindow(
                    minutes: minutes,
                    usedPercent: used,
                    resetsAt: Date(timeIntervalSince1970: resets)
                )
            }
            .sorted { $0.minutes < $1.minutes }
    }

    /// A mode this build has never heard of reads as off rather than dropping
    /// the frame: the daemon ships inside the app bundle, so the two agree by
    /// construction — but a user running a newer daemon against an older app
    /// should lose one control, not the whole panel.
    private static func decodeKeepAwake(_ raw: Any?) -> KeepAwakeState {
        guard let row = raw as? [String: Any],
            let mode = (row["mode"] as? String).flatMap(KeepAwakeMode.init(rawValue:))
        else { return .off }
        return KeepAwakeState(mode: mode, active: row["active"] as? Bool ?? false)
    }

    /// Both keys travel together or not at all; a half-present or malformed
    /// pair decodes to nil so the menubar shows no delta rather than one
    /// computed against a zero it never received.
    private static func decodePrev(_ dict: [String: Any]) -> (tokens: Int, cost: Decimal)? {
        guard let tokens = dict["prev_tokens"] as? Int,
            let costRaw = dict["prev_cost"] as? String,
            let cost = Decimal(string: costRaw)
        else { return nil }
        return (tokens, cost)
    }
}
