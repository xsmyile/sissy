import Foundation

/// What OpenAI answers about a Codex account's resets, and the one request
/// Sissy makes that spends something on the user's behalf.
///
/// Three payloads, measured 2026-09-24 against `chatgpt.com/backend-api` and
/// read against the Codex CLI's own client (`backend-client`, 0.156.1). The
/// count rides the usage reply every poll already makes. The list that dates
/// each reset is `wham/rate-limit-reset-credits`. The spend is a `POST` to
/// that path's `/consume`, carrying a request id the vendor redeems once, so a
/// retry of an attempt nobody heard the answer to cannot spend a second reset.
///
/// Everything here is a boundary, so nothing is trusted past the shape it is
/// checked for.
enum CodexResetCredits {
    static let listURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let consumeURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    private static let summaryKey = "rate_limit_reset_credits"
    private static let availableStatus = "available"

    /// One reset the account still holds.
    struct Credit: Sendable, Equatable {
        let id: String
        let expiresAt: Date?
        let title: String?
    }

    /// What the vendor said to one spend, in its own four words.
    enum Answer: String, Sendable, Equatable {
        case reset
        case alreadyRedeemed = "already_redeemed"
        case nothingToReset = "nothing_to_reset"
        case noCredit = "no_credit"
    }

    // MARK: - Reading

    /// The count on the usage reply, nil where the block is absent or not the
    /// shape measured.
    static func summary(_ body: [String: Any]) -> LimitResets? {
        guard let block = body[summaryKey] as? [String: Any],
            let available = count(block["available_count"])
        else { return nil }
        return LimitResets(available: available, applicable: count(block["applicable_available_count"]))
    }

    private static func count(_ raw: Any?) -> Int? {
        guard let value = raw as? Int, value >= 0 else { return nil }
        return value
    }

    /// The resets the list still offers, soonest to lapse first and the ones
    /// that never lapse last, which is the order both of OpenAI's own clients
    /// spend them in.
    ///
    /// A reset whose date has passed is dropped even while the list still
    /// calls it available: spending it answers `no_credit`, and offering it is
    /// a button that fails.
    static func credits(_ body: [String: Any], now: Date) -> [Credit] {
        guard let rows = body["credits"] as? [[String: Any]] else { return [] }
        let credits = rows.compactMap { row -> Credit? in
            guard row["status"] as? String == availableStatus,
                let id = UsageReaderShared.sanitizedDisplayText(row["id"] as? String)
            else { return nil }
            let expiresAt = (row["expires_at"] as? String).flatMap(UsageReaderShared.parseTimestamp)
            if let expiresAt, expiresAt <= now { return nil }
            return Credit(
                id: id, expiresAt: expiresAt,
                title: UsageReaderShared.sanitizedDisplayText(row["title"] as? String))
        }
        return credits.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The vendor's answer to a spend, nil for one Sissy cannot read, which is
    /// an answer that says nothing about whether the reset happened.
    static func answer(_ body: [String: Any]) -> Answer? {
        (body["code"] as? String).flatMap(Answer.init(rawValue:))
    }

    // MARK: - The wire

    /// Every reset the account holds, dated.
    static func fetchCredits(_ credential: CodexCredential) async throws -> [Credit] {
        let body = try await CodexUsageSource.send(
            CodexUsageSource.request(listURL, credential: credential))
        return credits(body, now: Date())
    }

    /// Spends one reset. `requestID` is what makes the call safe to repeat:
    /// the vendor redeems a request id once and answers `already_redeemed` to
    /// the second.
    static func consume(
        _ credential: CodexCredential, requestID: String, creditID: String?
    ) async throws -> Answer {
        var request = CodexUsageSource.request(consumeURL, credential: credential)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = ["redeem_request_id": requestID]
        if let creditID { payload["credit_id"] = creditID }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        guard let answer = answer(try await CodexUsageSource.send(request)) else {
            throw UsageRequestError.malformedPayload
        }
        return answer
    }
}

/// How spending a reset ended, as the panel words it.
enum CodexResetOutcome: Sendable, Equatable {
    /// The windows are back to zero. `already_redeemed` lands here too: it is
    /// the vendor saying an earlier attempt under the same request id did it.
    case reset
    /// Nothing was spent, because nothing needed resetting yet.
    case nothingToReset
    /// The account had no reset left to spend, or the one asked for lapsed.
    case noCredit
    /// No answer Sissy could read, so it may or may not have happened. Trying
    /// again sends the same request id, which is what makes that safe.
    case unconfirmed
    /// OpenAI refused the credential. The request was never taken.
    case refused
    /// There was no credential to send, or no reader for the account.
    case unavailable

    init(_ answer: CodexResetCredits.Answer) {
        switch answer {
        case .reset, .alreadyRedeemed: self = .reset
        case .nothingToReset: self = .nothingToReset
        case .noCredit: self = .noCredit
        }
    }
}
