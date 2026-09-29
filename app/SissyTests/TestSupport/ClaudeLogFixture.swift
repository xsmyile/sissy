import Foundation

/// One Claude Code assistant turn as the CLI logs it, for suites that place
/// turns in a tree a tail reads.
///
/// Every field but the input count is zero, so a day's `totalTokens` is the sum
/// of the inputs written. `messageId` and `cwd` are left out of the line when
/// nil, as the CLI leaves them out of older logs; `oneHourWrites` adds the
/// `cache_creation` split and bills that many tokens as one-hour cache writes.
enum ClaudeLogFixture {
    /// `ISO8601DateFormatter` is documented thread-safe, so one instance serves
    /// every suite running in parallel.
    nonisolated(unsafe) private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func turnLine(
        requestId: String,
        model: String,
        input: Int,
        at when: Date = Date(),
        messageId: String? = nil,
        cwd: String? = nil,
        oneHourWrites: Int? = nil
    ) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
        let idField = messageId.map { "\"id\":\"\($0)\"," } ?? ""
        let cacheSplit =
            oneHourWrites.map {
                ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":\($0)}"
            } ?? ""
        return """
            {"type":"assistant","timestamp":"\(timestamps.string(from: when))",\
            \(cwdField)"requestId":"\(requestId)",\
            "message":{\(idField)"model":"\(model)",\
            "usage":{"input_tokens":\(input),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":\(oneHourWrites ?? 0)\
            \(cacheSplit)}}}
            """
    }

    /// Replaces `url` with a log holding the one turn `turnLine` describes.
    static func writeTurn(
        to url: URL,
        requestId: String,
        model: String,
        input: Int,
        at when: Date = Date(),
        messageId: String? = nil,
        cwd: String? = nil,
        oneHourWrites: Int? = nil
    ) throws {
        let line = turnLine(
            requestId: requestId, model: model, input: input, at: when,
            messageId: messageId, cwd: cwd, oneHourWrites: oneHourWrites)
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
