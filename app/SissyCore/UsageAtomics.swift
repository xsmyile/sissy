import Foundation

/// A value is copied under one lock, so readers cannot combine fields from
/// different updates. Mutation stays synchronous and never holds a lock over await.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }
    func load() -> Value { lock.withLock { value } }
    func store(_ value: Value) { lock.withLock { self.value = value } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

/// One account's own reading of the limits it is under.
///
/// Deliberately a smaller type than `ProviderSignals` rather than a nesting of
/// it: a provider answers for a day's tokens, a plan and an activity stamp,
/// and an account answers for none of those. What an account has is an
/// identity and a ceiling, and a type that carried the rest would invite a
/// caller to read a token count off something that never counted any.
///
/// The spend is deliberately absent and cannot be added. A Claude Code log
/// line names no account, so the tokens belong to the config home rather than
/// to whoever was signed in when it was written — a day spanning a sign-in is
/// genuinely one number across two accounts. The gauge is the whole of what an
/// account answers for.
struct AccountSignals: Sendable, Equatable, Identifiable {
    /// Anthropic's own account uuid, which is the key both the OAuth profile
    /// and claude.ai name this account with — measured, one id across both.
    let id: String
    let account: ProviderAccount?
    let plan: String?
    let planTier: String?
    var windows: [UsageWindow] = []
    var credits: ProviderCredits?
    var limitsState: ProviderLimitsState = .quiet
    var limitsObservedAt: Date?
    /// Whether this is the account the CLI itself is signed in as, which is
    /// the one whose future spend lands in the day beside it.
    var isSignedIn: Bool = false

    /// The same reading ordered by period, on the rule
    /// `ProviderSignals.live()` applies to its own — a bucket past its reset
    /// kept with the rest, so an account's gauges and the row above them
    /// cannot disagree about whether a window still exists.
    func live(at now: Date = Date()) -> Self {
        var copy = self
        copy.windows = UsageWindow.ordered(windows)
        copy.limitsState = limitsState.live(at: now)
        return copy
    }
}

/// Everything one source answers for besides its token totals, published as a
/// single value.
///
/// One value rather than a getter each because the fields are read together
/// and describe one moment: a plan taken from one publication beside an
/// account from the next is a reading that never existed. It is also what
/// makes "has anything about this provider changed" a single comparison,
/// which is how a lapsed authorization reaches the panel on a day where no
/// token event will follow it.
struct ProviderSignals: Sendable, Equatable {
    /// Empty whenever the provider reports no limits — an API-key user, or a
    /// CLI that has not surfaced a window yet. The panel falls back to the
    /// share-of-today bar rather than rendering an empty gauge.
    var windows: [UsageWindow] = []
    /// Vendor's own plan token (`max`, `plus`), nil when the provider names
    /// none. Raw rather than a label so the app owns the wording — same
    /// division as a provider's `id`, which the app turns into a display name.
    var plan: String?
    /// Limit tier the plan is metered at (`max_5x`), for the one vendor that
    /// publishes one. Only ever shown alongside `plan`.
    var planTier: String?
    /// Who this provider is signed in as, when its own files say.
    var account: ProviderAccount?
    /// What the vendor has billed against a spend cap, for the providers that
    /// publish one. Nil for every other, and for an account that has never
    /// enabled the facility.
    var credits: ProviderCredits?
    /// Why the windows are missing, when they are and when the user can do
    /// something about it.
    var limitsState: ProviderLimitsState = .quiet
    /// When the windows beside it were taken, on the clock of whoever took
    /// them — Sissy's for a fetch it made, the CLI's own event stamp for the
    /// buckets it only ever reads off a rollout. Nil until a reading lands.
    /// The panel prints it: gauges Sissy cannot refresh on demand are stale
    /// by design, and an age is the difference between saying so and letting
    /// a frame from the other provider imply otherwise.
    var limitsObservedAt: Date?
    /// The newest event this source has seen *since its cold scan finished*,
    /// as the event was stamped. Nil through the backfill, which is what
    /// separates a turn landing now from a reconstruction of the ones that
    /// landed before Sissy was launched.
    var lastActivityAt: Date?
    /// Every account this provider can answer for, the signed-in one
    /// included, in a stable order.
    ///
    /// Empty for a provider that answers for one account, which is every
    /// provider until a second session is linked — and what makes a
    /// single-account install render exactly as it did before this existed.
    ///
    /// The fields above are that signed-in account's reading and stay where
    /// they are: they are what a row, a badge and a gauge have always read,
    /// and moving them would churn every consumer to express something none
    /// of them asked a different question about. This is the list the
    /// surfaces that *do* ask iterate, and the signed-in account appears in
    /// it too, so nothing has to special-case the first one.
    var accounts: [AccountSignals] = []

    /// The same reading ordered by the period each bucket measures, and every
    /// account's reading behind it given the same treatment — one of them is
    /// this same reading under its own name, and two rows drawn from one
    /// moment must not disagree about which of their windows has rolled over.
    ///
    /// What ordering means, and why a bucket past its reset stays in the
    /// list, is `UsageWindow.ordered`. Why a vendor's block does not outlive
    /// the deadline it named, where a window does outlive its reset, is
    /// `ProviderLimitsState.live(at:)`.
    func live(at now: Date = Date()) -> Self {
        var copy = self
        copy.windows = UsageWindow.ordered(windows)
        copy.limitsState = limitsState.live(at: now)
        copy.accounts = accounts.map { $0.live(at: now) }
        return copy
    }
}

/// What a source publishes for readers outside its own isolation.
///
/// Nonisolated on purpose: the aggregator reads this while the provider that
/// just emitted still holds its own actor, so an `await` here would deadlock
/// the pair — the provider waiting on its callback, the callback waiting on
/// the provider. A source that publishes nothing takes the default.
protocol SourceSignals: Sendable {
    nonisolated func currentSignals() -> ProviderSignals
}

extension SourceSignals {
    nonisolated func currentSignals() -> ProviderSignals { ProviderSignals() }
}

extension LockedValue: SourceSignals where Value == ProviderSignals {
    func currentSignals() -> ProviderSignals { load().live() }
}
