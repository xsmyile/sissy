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
            state: dict["state"] as? String ?? defaultState,
            ts: dict["ts"] as? Int ?? 0,
            primary: dict["primary"] as? String ?? tokens,
            primaryLabel: dict["primary_label"] as? String ?? defaultPrimaryLabel,
            devicePresent: dict["device_present"] as? Bool ?? false,
            milestone: dict["milestone"] as? String,
            providers: decodeProviders(dict["providers"]),
            prev: decodePrev(dict)
        )
    }

    static let placeholder = "..."
    private static let defaultState = "think"
    private static let defaultPrimaryLabel = "TOKENS"

    private static func decodeProviders(_ raw: Any?) -> [DisplayFrame.ProviderSlice] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                let tokens = row["tokens"] as? Int,
                let costRaw = row["cost"] as? String,
                let cost = Decimal(string: costRaw)
            else { return nil }
            return DisplayFrame.ProviderSlice(id: id, tokens: tokens, cost: cost)
        }
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
