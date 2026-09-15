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

    /// The same reading with expired buckets dropped and the rest ordered by
    /// the period they measure.
    ///
    /// A window past its reset describes a period that no longer exists. The
    /// order is here rather than at each producer because the panel draws the
    /// list in the order it is handed: two vendors listing the same two
    /// periods the other way round would stack their blocks differently for
    /// no reason a reader could see. Which row the block *leads* on is not
    /// positional — `UsagePanelSnapshot.binding` decides it from the pace.
    func live(now: Date = Date()) -> Self {
        var copy = self
        copy.windows =
            windows
            .filter { $0.resetsAt.map { $0 > now } ?? true }
            .sorted { ($0.minutes, $0.scope ?? "") < ($1.minutes, $1.scope ?? "") }
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
