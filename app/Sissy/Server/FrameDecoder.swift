import Foundation

/// Parses the daemon's `frame` messages into a typed `DisplayFrame`.
///
/// Lives apart from `WebSocketClient` because the frame shape has no schema
/// shared with `app/SissyServer/Hub.swift` — keeping the parse pure is what
/// lets a test pin the wire contract without a live socket.
enum FrameDecoder {
    static func decode(_ text: String) -> DisplayFrame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> DisplayFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            dict["type"] as? String == "frame"
        else { return nil }

        let tokens = dict["tokens"] as? String ?? placeholder
        return DisplayFrame(
            tokens: tokens,
            cost: dict["cost"] as? String ?? placeholder,
            burn: dict["burn"] as? String ?? placeholder,
            ts: dict["ts"] as? Int ?? 0,
            primary: dict["primary"] as? String ?? tokens,
            primaryLabel: dict["primary_label"] as? String ?? defaultPrimaryLabel,
            providers: decodeProviders(dict["providers"]),
            prev: decodePrev(dict),
            keepAwake: decodeKeepAwake(dict["keep_awake"])
        )
    }

    static let placeholder = "..."
    private static let defaultPrimaryLabel = "TOKENS"

    private static func decodeProviders(_ raw: Any?) -> [DisplayFrame.ProviderSlice] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                let tokens = row["tokens"] as? Int,
                let costRaw = row["cost"] as? String,
                let cost = Decimal(string: costRaw)
            else { return nil }
            return DisplayFrame.ProviderSlice(
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
    private static func decodeWindows(_ raw: Any?) -> [DisplayFrame.UsageWindow] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return
            rows
            .compactMap { row -> DisplayFrame.UsageWindow? in
                guard let minutes = row["minutes"] as? Int, minutes > 0,
                    let used = row["used_percent"] as? Double,
                    let resets = row["resets_at"] as? Double
                else { return nil }
                return DisplayFrame.UsageWindow(
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
    private static func decodePrev(_ dict: [String: Any]) -> DisplayFrame.PrevTotals? {
        guard let tokens = dict["prev_tokens"] as? Int,
            let costRaw = dict["prev_cost"] as? String,
            let cost = Decimal(string: costRaw)
        else { return nil }
        return DisplayFrame.PrevTotals(tokens: tokens, cost: cost)
    }
}
