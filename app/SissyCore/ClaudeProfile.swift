import Foundation

/// Reads what Claude Code records about the account in its own config file:
/// the subscription plan, and the usage credits the vendor has billed against
/// the user's spend cap.
///
/// Nothing else on the Claude side answers for it. The usage endpoint the
/// limits probe polls carries utilization buckets and no plan field
/// (measured), and the copy in the login keychain sits behind the
/// authorization prompt the `claudeLimits` toggle exists to gate — reaching
/// for it would put a keychain dialog in front of someone who only switched
/// limits on. `.claude.json` is therefore the one source that also
/// answers for a user who never enabled limits.
///
/// A class rather than an actor because `UsageProvider.currentPlan()` is
/// nonisolated: the aggregator reads it while the emitting provider still
/// holds its own actor, so an actor hop here would deadlock the pair.
final class ClaudeProfileSource: @unchecked Sendable {
    private static let fileName = ".claude.json"
    private static let configDirEnvVar = "CLAUDE_CONFIG_DIR"

    /// Claude Code rewrites this file on nearly every interaction — project
    /// history, feature counters — so a changed mtime is no evidence anything
    /// this type reads has moved. The floor is what keeps the safety-net poll
    /// from re-parsing the file on every one of those writes.
    ///
    /// It is the tail's own cadence rather than the quarter of an hour the
    /// plan alone justified: the credits move with every request, and a figure
    /// a user checks against their spend cap is worth a 320 KB parse a minute,
    /// which costs about a millisecond.
    private static let minimumReparseInterval: TimeInterval = 60

    /// `oauthAccount.organizationType` prefixes the plan the CLI displays:
    /// `claude_max` against the bare `max` its own label switch takes.
    /// Verified against 2.1.267, whose enumeration is exactly
    /// pro / max / team / enterprise.
    private static let planPrefix = "claude_"

    /// `oauthAccount.userRateLimitTier` prefixes the tier the same way:
    /// `default_claude_max_5x` for the account metered at Max 5x. Only the
    /// two `max` multipliers appear in 2.1.267, which is why the tier is
    /// treated as a decoration on the plan and never as the plan itself.
    private static let tierPrefix = "default_claude_"

    /// Claude Code's config file, in the config home the CLI resolves for
    /// itself: `CLAUDE_CONFIG_DIR` when set, `$HOME` otherwise — the same
    /// env-var deference `ServerConfig.resolvedCodexDataDir` pays `CODEX_HOME`.
    /// Deliberately not derived from `claudeDataDir`: that setting points at
    /// the projects tree, which is not where this file lives.
    static var defaultURL: URL {
        let configured = ProcessInfo.processInfo.environment[configDirEnvVar]
        let configHome =
            configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return configHome.appendingPathComponent(fileName)
    }

    private let url: URL
    private let lock = NSLock()
    private var profile: Profile?
    private var credits: ProviderCredits?
    private var lastParsedAt: Date = .distantPast
    private var lastMTime: TimeInterval = 0

    /// `oauthAccount.seatTier` names which seat of a Team plan the account
    /// holds. Unprefixed, unlike the two above.
    private static let seatKey = "seatTier"
    private static let emailKey = "emailAddress"
    private static let organizationKey = "organizationName"

    /// Plan, its limit tier and the account they belong to, held together so
    /// neither a tier nor an identity can outlive the plan it decorates.
    struct Profile: Sendable, Equatable {
        let plan: String
        let tier: String?
        let account: ProviderAccount?
    }

    /// Keys of the cached usage payload, which is the endpoint's answer stored
    /// verbatim. Named here rather than inline because the same shape is what
    /// `ClaudeLimitsProbe` parses off the wire.
    private static let usageCacheKey = "cachedUsageUtilization"
    private static let usageFetchedAtKey = "fetchedAtMs"
    private static let usageBodyKey = "utilization"
    private static let spendKey = "spend"

    /// Outcome of reading the config file, on the same reasoning as
    /// `ClaudeCredentialsLookup`: naming no plan and answering nothing are
    /// different states. The first is an account without one — an API-key
    /// user, or a CLI signed out — and clears the plan on the row. The second
    /// is a payload this type could not parse, which is no information at
    /// all, and must leave the last good reading where it is.
    enum Reading: Sendable, Equatable {
        case found(Profile)
        case absent
        case unreadable
    }

    init(url: URL = ClaudeProfileSource.defaultURL) {
        self.url = url
    }

    /// Plan last read, as the CLI's own token (`max`, `team`). Nil until a
    /// refresh finds one, and nil for good for an API-key user or a config
    /// file with no `oauthAccount` — which leaves the panel row without a
    /// plan rather than guessing at one.
    func currentPlan() -> String? { lock.withLock { profile?.plan } }

    /// Limit tier the account is metered at (`max_5x`), when the CLI names one
    /// and a plan came with it.
    func currentPlanTier() -> String? { lock.withLock { profile?.tier } }

    /// Address, organisation and seat, when the CLI's config names them. Nil
    /// for the same accounts `currentPlan()` answers nil for — there is no
    /// `oauthAccount` to read either way.
    func currentAccount() -> ProviderAccount? { lock.withLock { profile?.account } }

    /// Credits the vendor has billed against the user's spend cap, as of the
    /// CLI's last fetch. Nil for an account whose config names none, which is
    /// every account that has never turned the facility on.
    func currentCredits() -> ProviderCredits? { lock.withLock { credits } }

    /// Re-reads the file when it has changed on disk and the floor has
    /// passed. A file that has stopped naming a plan clears the held one — a
    /// signed-out CLI should not leave a stale plan on the row — while a
    /// payload that would not parse leaves both the reading and the
    /// bookkeeping untouched, so the next poll tries again instead of
    /// treating a failed read as an answer.
    /// `userInitiated` is the caller saying someone just asked for this, which
    /// is the one thing allowed past the floor. The floor exists so a poll
    /// every minute does not re-parse 300 KB for a value that changes on the
    /// order of never; a person pressing refresh is not that, and making them
    /// wait a quarter of an hour for the answer is the button failing at its
    /// only job. The mtime gate still applies either way — an unchanged file
    /// has nothing new to say to anyone.
    func refresh(now: Date = Date(), userInitiated: Bool = false) {
        let (parsedBefore, knownMTime, dueAt) = lock.withLock {
            (lastParsedAt != .distantPast, lastMTime, lastParsedAt + Self.minimumReparseInterval)
        }
        if parsedBefore && !userInitiated && now < dueAt { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return }
        if parsedBefore && abs(mtime - knownMTime) < UsageReaderShared.mtimeTolerance { return }
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let reading = Self.readProfile(root)
        let billed = Self.readCredits(root)
        lock.withLock {
            profile = if case .found(let found) = reading { found } else { nil }
            credits = billed
            lastParsedAt = now
            lastMTime = mtime
        }
    }

    /// Reads a `.claude.json` payload. A shape that parses but names no plan
    /// is `.absent`, so a config file the CLI reorganises costs the panel a
    /// badge rather than showing a wrong one; bytes that are not a JSON object
    /// at all are `.unreadable`, which is not the same claim.
    static func read(_ data: Data) -> Reading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable
        }
        return readProfile(root)
    }

    /// The credits block of a `.claude.json` payload, for a caller holding the
    /// bytes rather than the parsed object.
    static func readCredits(_ data: Data) -> ProviderCredits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return readCredits(root)
    }

    private static func readProfile(_ root: [String: Any]) -> Reading {
        guard let account = root["oauthAccount"] as? [String: Any],
            let plan = UsageReaderShared.sanitizedPlanToken(
                stripping(planPrefix, from: account["organizationType"] as? String)
            )
        else { return .absent }
        let tier = UsageReaderShared.sanitizedPlanToken(
            stripping(tierPrefix, from: account["userRateLimitTier"] as? String)
        )
        return .found(
            Profile(
                plan: plan,
                tier: tier,
                account: ProviderAccount(
                    email: UsageReaderShared.sanitizedDisplayText(account[emailKey] as? String),
                    organization: UsageReaderShared.sanitizedDisplayText(
                        account[organizationKey] as? String),
                    seat: UsageReaderShared.sanitizedPlanToken(account[seatKey] as? String)
                )
            )
        )
    }

    /// The vendor's own answer for what it has billed against the spend cap,
    /// read out of the payload the CLI cached from the usage endpoint.
    ///
    /// Foreign input, so it is parsed as a boundary: every field must be
    /// present and the pair must agree on a currency and a scale, because a
    /// used amount in one denomination against a cap in another is not a
    /// reading that can be rendered — it is two readings. A shape that fails
    /// any of that answers nil, which leaves the row off rather than putting
    /// a number on screen that nobody can vouch for.
    private static func readCredits(_ root: [String: Any]) -> ProviderCredits? {
        guard let cache = root[usageCacheKey] as? [String: Any],
            let fetchedAtMs = cache[usageFetchedAtKey] as? Double,
            let body = cache[usageBodyKey] as? [String: Any],
            let spend = body[spendKey] as? [String: Any],
            let used = money(spend["used"]),
            let cap = money(spend["limit"]),
            used.currency == cap.currency,
            used.exponent == cap.exponent
        else { return nil }
        return ProviderCredits(
            isEnabled: spend["enabled"] as? Bool ?? true,
            usedMinor: used.minor,
            capMinor: cap.minor,
            currency: used.currency,
            exponent: used.exponent,
            observedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000)
        )
    }

    /// One money object of the payload. The currency has to look like an
    /// ISO 4217 code before it is carried any further: it reaches a formatter,
    /// and a formatter handed arbitrary text out of a file is how a display
    /// string becomes an injection.
    private static func money(_ raw: Any?) -> (minor: Int, currency: String, exponent: Int)? {
        guard let object = raw as? [String: Any],
            let minor = object["amount_minor"] as? Int, minor >= 0,
            let exponent = object["exponent"] as? Int, (0...4).contains(exponent),
            let currency = object["currency"] as? String,
            currency.count == 3,
            currency.allSatisfy({ $0.isASCII && $0.isUppercase })
        else { return nil }
        return (minor, currency, exponent)
    }

    private static func stripping(_ prefix: String, from raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }
}
