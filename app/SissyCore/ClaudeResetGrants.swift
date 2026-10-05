import Foundation

/// What Anthropic answers about a Claude account's resets, and the request
/// that spends one on the user's behalf.
///
/// Read against Claude Code 2.1.289's own client and measured 2026-10-05
/// against `api.anthropic.com`. The resets ride the usage reply the limits
/// probe already polls, but only when it asks for them with `cedar_ember=1`:
/// without it the block is `null`. The spend is a `POST` to the organisation's
/// `reset_rate_limits` carrying a request id, which the CLI sends again for an
/// attempt it heard no answer to, so a retry cannot spend a second reset.
///
/// **The vendor decides by User-Agent who is offered them.** The same token
/// and the same query answered `ineligible_reason: "surface"` with no agent,
/// with `claude-cli` alone and with a Sissy agent naming the CLI after it,
/// `"cli_version"` for `claude-cli/2.1.0`, and the grant for the version
/// installed. So the request names the CLI the way the CLI does, at the
/// version the CLI last recorded, and an unknown version sends no agent at
/// all: that is a reply with no resets in it, which draws no row.
///
/// Everything here is a boundary, so nothing is trusted past the shape it is
/// checked for.
enum ClaudeResetGrants {
    /// The query the usage request carries to have the block filled in. The
    /// CLI pairs it with `skip_spend=1`, which would cost the credits row its
    /// `spend` block; measured 2026-10-05, the reply carries both without it.
    static let usageQuery = URLQueryItem(name: "cedar_ember", value: "1")
    private static let statusKey = "cedar_ember"
    private static let program = "cedar_ember"
    private static let claimHost = "https://api.anthropic.com/api/organizations/"
    private static let claimPath = "/reset_rate_limits"
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 25

    /// The two window names this build draws a gauge for, to their length.
    /// The vendor lists more (`seven_day_overage_included` among them), and
    /// a reset clearing one the page never draws has nothing to say about it.
    private static let windowMinutes: [String: Int] = ["five_hour": 300, "seven_day": 10_080]

    /// The shapes the CLI checks a grant id and a request id against before it
    /// sends either: `[a-z0-9_-]{1,40}` and `[A-Za-z0-9_-]{1,64}`.
    private static let grantLimit = 40
    private static let requestLimit = 64
    private static let separators: Set<Character> = ["_", "-"]

    /// The resets on one reading, and the grant a press would spend.
    struct Status: Sendable, Equatable {
        let resets: LimitResets
        let grantID: String
    }

    /// What the vendor said to one spend, in its own words.
    enum Answer: String, Sendable, Equatable {
        case reset
        case alreadyUsed = "already_used"
        case notLimited = "not_limited"
        case cooldown
        case ineligible
        case unavailable
    }

    // MARK: - Reading

    /// The agent the CLI sends, at the version given, or nil for a version
    /// that is not one: an agent naming a version the vendor cannot read is
    /// answered `cli_version`, and none at all reads the same.
    static func userAgent(cliVersion: String?) -> String? {
        guard let cliVersion, isVersion(cliVersion) else { return nil }
        return "claude-cli/\(cliVersion) (external, cli)"
    }

    /// The resets the reply offers, or nil where it offers none.
    ///
    /// The count is every grant still in date; the caption, the expiry and the
    /// windows cleared are the one the vendor names next, which is the one a
    /// press spends. Whether it applies now is the grant's own word for it:
    /// usable now, not paused, and either usable any time or the account at a
    /// limit, which is the CLI's own reading of the same fields. An
    /// account the vendor calls ineligible gets no row, because what it says
    /// about why is not something the user can act on, and neither does a
    /// grant that clears no window the page draws: nothing on it would move.
    static func status(_ body: [String: Any], now: Date) -> Status? {
        guard let block = body[statusKey] as? [String: Any],
            block["eligible"] as? Bool == true,
            let nextID = block["next_grant_id"] as? String,
            let grants = block["grants"] as? [Any]
        else { return nil }
        let live = grants.compactMap { $0 as? [String: Any] }.filter { grant in
            guard let left = count(grant["resets_left"]), left > 0 else { return false }
            guard let endsAt = grant["ends_at"], !(endsAt is NSNull) else { return true }
            return date(endsAt).map { $0 > now } ?? false
        }
        guard let next = live.first(where: { $0["id"] as? String == nextID }),
            isGrantID(nextID)
        else { return nil }
        let available = live.compactMap { count($0["resets_left"]) }.reduce(0, +)
        let atLimit = block["at_limit"] as? Bool == true
        let usable =
            next["usable_now"] as? Bool == true && next["paused"] as? Bool != true
            && (next["use_requires_limit"] as? Bool == false || atLimit)
        let clears = Set(
            (next["clears"] as? [Any])?.compactMap { ($0 as? String).flatMap { windowMinutes[$0] } }
                ?? [])
        guard !clears.isEmpty else { return nil }
        return Status(
            resets: LimitResets(
                available: available,
                applicable: usable ? count(next["resets_left"]) : 0,
                nextExpiry: date(next["ends_at"]),
                title: UsageReaderShared.sanitizedDisplayText(next["label"] as? String),
                clears: clears),
            grantID: nextID)
    }

    /// Three dot-separated runs of digits, which is every version the CLI
    /// has shipped under.
    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(isDigit) }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    static func isGrantID(_ text: String) -> Bool {
        (1...grantLimit).contains(text.count)
            && text.allSatisfy { isDigit($0) || ("a"..."z").contains($0) || separators.contains($0) }
    }

    static func isRequestID(_ text: String) -> Bool {
        (1...requestLimit).contains(text.count)
            && text.allSatisfy {
                isDigit($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || separators.contains($0)
            }
    }

    private static func count(_ raw: Any?) -> Int? {
        guard let value = raw as? Int, value >= 0 else { return nil }
        return value
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return UsageReaderShared.parseTimestamp(text)
    }

    static func answer(_ body: [String: Any]) -> Answer? {
        (body["result"] as? String).flatMap(Answer.init(rawValue:))
    }

    /// Whose a token is: the account the page names its rows by, and the
    /// organisation the spend is addressed to.
    struct Owner: Sendable, Hashable {
        let account: String
        let organization: String
    }

    /// Asked of the vendor with the token that will spend, rather than read
    /// off `.claude.json`: that file is the CLI's and can name the account
    /// the CLI was on before a switch, and a reset addressed to another
    /// account is a spend on one the user is not looking at.
    static func owner(token: String, userAgent: String?) async throws -> Owner {
        let profile = try await UsageRequestError.object(
            answering: request(profileURL, token: token, userAgent: userAgent))
        return try owner(profile)
    }

    static func owner(_ profile: [String: Any]) throws -> Owner {
        guard let account = (profile["account"] as? [String: Any])?["uuid"] as? String,
            !account.isEmpty,
            let organization = (profile["organization"] as? [String: Any])?["uuid"] as? String,
            UUID(uuidString: organization) != nil
        else { throw UsageRequestError.malformedPayload }
        return Owner(account: account, organization: organization)
    }

    /// Spends the grant named. `requestID` is what makes the call safe to
    /// repeat: the CLI resends it for an attempt it heard no answer to, and
    /// reads `already_used` on that resend as the first having landed.
    static func claim(
        token: String, userAgent: String?, organization: String, grantID: String,
        requestID: String
    ) async throws -> Answer {
        guard isGrantID(grantID), isRequestID(requestID)
        else { throw UsageRequestError.malformedPayload }
        guard UUID(uuidString: organization) != nil,
            let url = URL(string: claimHost + organization + claimPath)
        else {
            throw UsageRequestError.malformedPayload
        }
        var request = request(url, token: token, userAgent: userAgent)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "program": program, "grant_id": grantID, "request_id": requestID,
        ])
        guard let answer = answer(try await UsageRequestError.object(answering: request)) else {
            throw UsageRequestError.malformedPayload
        }
        return answer
    }

    /// A request carrying the CLI's own headers, which is what every call
    /// here and the usage poll send.
    static func request(_ url: URL, token: String, userAgent: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return request
    }
}

extension LimitResetOutcome {
    /// `retrying` is whether the press resent a request id an earlier press
    /// heard no answer to, which is what turns three of the vendor's answers
    /// from "nothing was spent" into "the earlier one may have", as in the
    /// CLI's own wording of them.
    init(_ answer: ClaudeResetGrants.Answer, retrying: Bool) {
        switch answer {
        case .reset: self = .reset
        case .alreadyUsed: self = retrying ? .reset : .noCredit
        case .notLimited: self = retrying ? .mayHaveLanded : .nothingToReset
        case .ineligible: self = retrying ? .mayHaveLanded : .noCredit
        case .cooldown: self = retrying ? .mayHaveLanded : .cooldown
        case .unavailable: self = .unconfirmed
        }
    }
}
