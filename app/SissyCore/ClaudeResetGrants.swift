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
    static let usageQuery = URLQueryItem(name: queryName, value: queryValue)
    private static let queryName = "cedar_ember"
    private static let queryValue = "1"
    /// The same query as claude.ai's paths spell it, which are strings.
    /// Measured 2026-11-11, a Team account's claude.ai usage reply carries the
    /// block with it, under `surface: claude_ai`.
    static let usageQueryString = "\(queryName)=\(queryValue)"
    private static let statusKey = "cedar_ember"
    private static let program = "cedar_ember"
    private static let claimHost = "https://api.anthropic.com/api/organizations/"
    private static let claimPath = "/reset_rate_limits"
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 25

    /// The window names this build draws a gauge for, to their length.
    private static let planWindows: [String: Int] = ["five_hour": 300, "seven_day": 10_080]
    /// The weekly window of the one model metered on its own. Measured
    /// 2026-11-11: a Fable reset clears this name alone, and its
    /// `percent_used` matched the `weekly_scoped` Fable entry of `limits` to
    /// the point, where the plan-wide weekly read 30 against 12.
    private static let scopedWeekly = "seven_day_overage_included"
    private static let weekMinutes = 10_080

    /// The shapes the CLI checks a grant id and a request id against before it
    /// sends either: `[a-z0-9_-]{1,40}` and `[A-Za-z0-9_-]{1,64}`.
    private static let grantLimit = 40
    private static let requestLimit = 64
    private static let separators: Set<Character> = ["_", "-"]

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
    /// One grant per kind of reset the account holds, the one the vendor names
    /// next first, because a press spends the grant it names and the vendor
    /// lists a full reset beside a Fable one. Whether one applies now is the
    /// grant's own word for it: usable now, not paused, and either usable any
    /// time or the account at a limit, which is the CLI's own reading of the
    /// same fields. An account the vendor calls ineligible gets no row,
    /// because what it says about why is not something the user can act on,
    /// and neither does a grant that moves no window the page draws.
    static func status(_ body: [String: Any], now: Date) -> LimitResets? {
        guard let block = body[statusKey] as? [String: Any],
            block["eligible"] as? Bool == true,
            let listed = block["grants"] as? [Any]
        else { return nil }
        let atLimit = block["at_limit"] as? Bool == true
        let scope = scopedWeeklyModel(body)
        let offered = listed.compactMap { raw in
            (raw as? [String: Any]).flatMap { grant($0, atLimit: atLimit, scope: scope, now: now) }
        }
        guard let next = block["next_grant_id"] as? String, offered.contains(where: { $0.id == next })
        else { return nil }
        let grants = offered.filter { $0.id == next } + offered.filter { $0.id != next }
        return LimitResets(
            available: grants.map(\.left).reduce(0, +),
            applicable: grants.filter(\.appliesNow).map(\.left).reduce(0, +),
            nextExpiry: grants.compactMap(\.expiry).min(),
            grants: grants)
    }

    /// One grant, or nil for one that is spent, lapsed, misshapen, or moves
    /// nothing the page draws.
    private static func grant(
        _ raw: [String: Any], atLimit: Bool, scope: String?, now: Date
    ) -> LimitResetGrant? {
        guard let id = raw["id"] as? String, isGrantID(id),
            let left = count(raw["resets_left"]), left > 0
        else { return nil }
        let expiry = date(raw["ends_at"])
        if let endsAt = raw["ends_at"], !(endsAt is NSNull) {
            guard let expiry, expiry > now else { return nil }
        }
        let names = (raw["clears"] as? [Any])?.compactMap { $0 as? String } ?? []
        let clears = Set(names.compactMap { window(named: $0, scope: scope) }).sorted()
        guard !clears.isEmpty else { return nil }
        let givesBack = raw["gives_back_weekly"] as? Bool == true && clears.contains { $0.scope != nil }
        let usable =
            raw["usable_now"] as? Bool == true && raw["paused"] as? Bool != true
            && (raw["use_requires_limit"] as? Bool == false || atLimit)
        return LimitResetGrant(
            id: id, left: left, appliesNow: usable, expiry: expiry,
            label: UsageReaderShared.sanitizedDisplayText(raw["label"] as? String),
            clears: clears, givesBackWeekly: givesBack)
    }

    private static func window(named name: String, scope: String?) -> ResetWindow? {
        if let minutes = planWindows[name] { return ResetWindow(minutes: minutes, scope: nil) }
        guard name == scopedWeekly, let scope else { return nil }
        return ResetWindow(minutes: weekMinutes, scope: scope)
    }

    /// The model the reply meters a weekly window of its own for, when it
    /// meters exactly one: the reset names that window without naming the
    /// model, and with two of them there is no telling which it means.
    private static func scopedWeeklyModel(_ body: [String: Any]) -> String? {
        let models = Set(
            ClaudeUsagePayload.windows(body).filter { $0.minutes == weekMinutes }.compactMap(\.scope))
        return models.count == 1 ? models.first : nil
    }

    /// What one reply says about the account's resets, for the log: how many
    /// it offers, or why it offers none, in the vendor's own words where it
    /// gives any. The row only ever shows a count, so a reply that drew none
    /// left nothing behind to say whether the vendor refused the account, the
    /// agent, or simply had no grant left.
    static func note(_ body: [String: Any], now: Date) -> String {
        guard let block = body[statusKey] as? [String: Any] else {
            return "the reply carried no reset block"
        }
        guard block["eligible"] as? Bool == true else {
            let reason = UsageReaderShared.sanitizedDisplayText(block["ineligible_reason"] as? String)
            return "ineligible (\(reason ?? "no reason given"))"
        }
        guard let offered = status(body, now: now) else { return "no grant left that clears a window" }
        let usable = offered.applicable.map { "\($0) usable now" } ?? "usable now unknown"
        return "\(offered.available) available, " + usable
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
    /// the CLI was on before its credential moved, and a reset addressed to another
    /// account is a spend on one the user is not looking at.
    static func owner(token: String, userAgent: String?) async throws -> Owner {
        let profile = try await UsageRequestError.object(
            answering: request(
                ClaudeAccountProfile.profileURL, token: token, userAgent: userAgent,
                timeout: requestTimeout))
        return try owner(profile)
    }

    /// The profile read through `ClaudeAccountProfile.parse`, so the two
    /// readers of one reply cannot come to disagree about whose it is; only
    /// the organisation's shape is checked here, because a spend is addressed
    /// to it.
    static func owner(_ profile: [String: Any]) throws -> Owner {
        let identity = try ClaudeAccountProfile.parse(profile)
        guard let organization = identity.organizationUUID, UUID(uuidString: organization) != nil
        else { throw UsageRequestError.malformedPayload }
        return Owner(account: identity.uuid, organization: organization)
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
        var request = request(url, token: token, userAgent: userAgent, timeout: requestTimeout)
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
    /// here, the usage poll and `ClaudeAccountProfile.resolve` send. The
    /// timeout is the caller's: a spend waits longer than a poll.
    static func request(
        _ url: URL, token: String, userAgent: String?, timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
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
