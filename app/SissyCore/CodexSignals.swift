import Foundation

/// Codex's out-of-band facts, from the two places that answer for them.
///
/// The rollout tail reads the block Codex writes on its own turns; the usage
/// readers ask OpenAI. Neither replaces the other. The tail answers on a Mac
/// that is offline and for a token that has expired, and it is the only thing
/// that survives a relaunch with no request at all; the readers answer *now*,
/// which is what a gauge is for.
///
/// So the rule is the stamp rather than the source: **the later reading wins**,
/// and that is self-correcting in both directions. A live poll is newer than
/// the last turn by construction, and a reader that has stopped — switched
/// off, signed out, refused — stops moving its stamp and hands the row back to
/// the turns without anything having to remember which of them is preferred.
///
/// **One row per account, one reader per account.** The account the CLI is
/// signed into is read from the CLI's own credential, free; every other
/// account is read from a credential Sissy holds. What that costs is a second
/// reader for an account that is both — someone who linked the account they
/// are working in — and what it buys is that the link survives the CLI
/// switching away from it, which is the whole point of holding one.
struct CodexSignals: SourceSignals {
    /// What the tail published, which is also where the day's tokens and the
    /// activity stamp come from. Those are never the readers': a usage reply
    /// carries no spend, and an account the CLI is not signed into has none —
    /// a Codex rollout names no account, so the day belongs to the config home
    /// exactly as Claude Code's does.
    let rollout: LockedValue<ProviderSignals>
    /// One reader per credential, the CLI's own included. Held behind a lock
    /// because the set changes while the adapter lives — an account linked, an
    /// account forgotten — and read nonisolated because the aggregator asks
    /// while the emitting provider still holds its actor.
    let sources: LockedValue<[CodexUsageSource]>
    /// What each linked credential turned out to be. The only place an account
    /// reached through a link alone is named: nothing local knows who a
    /// `user-…` id is.
    let links: LockedValue<[String: CodexAccountLink]>

    init(
        rollout: LockedValue<ProviderSignals>,
        sources: LockedValue<[CodexUsageSource]>,
        links: LockedValue<[String: CodexAccountLink]> = LockedValue([:])
    ) {
        self.rollout = rollout
        self.sources = sources
        self.links = links
    }

    func currentSignals() -> ProviderSignals {
        let readers = sources.load()
        let signedIn = readers.first { $0.account == nil }
        // The signed-in account's own reading: the turns, with its own poll
        // laid over them. Resolved once and used twice — for the row and for
        // that account's entry — because the two must not be able to disagree
        // about what the account the CLI is on is doing.
        let own = Self.merge(rollout: rollout.load(), live: signedIn?.currentSignals())
        var reading = Self.row(
            own: own, linked: readers.filter { $0.account != nil }.map { $0.currentSignals() })
        reading.accounts = Self.perAccount(
            own: own, signedIn: signedIn, readers: readers, links: links.load())
        return reading
    }

    /// Which reading the provider's own row shows.
    ///
    /// The signed-in account's, whenever it has one — that is the account
    /// whose future spend lands in the day beside it. Failing that, a lone
    /// linked account, which is the only answer there is on a Mac whose
    /// `codex` is signed out or has never run. More than one and there is a
    /// choice to get wrong, so the row keeps its own empty answer and the
    /// accounts below it say the rest.
    ///
    /// What the fallback must never do is reach the signed-in account's own
    /// entry: a linked account's windows under the CLI account's name is two
    /// accounts on one row, which is the failure `ProviderSignals` exists to
    /// prevent.
    static func row(own: ProviderSignals, linked: [ProviderSignals]) -> ProviderSignals {
        guard own.windows.isEmpty, own.limitsObservedAt == nil, linked.count == 1 else {
            return own
        }
        return linked[0]
    }

    /// The tail's reading with the live one laid over it, or not, by stamp.
    ///
    /// The live reader's `limitsState` is taken whichever reading wins, and it
    /// is one of the two fields that cross that line. A state is the answer to
    /// "why is there nothing newer", which is a question only the reader that
    /// tried can answer — the tail never fails, it simply has nothing to add
    /// until the next turn. The resets are the other, because the rollouts do
    /// not carry them at all: there is no older reading for a newer turn to
    /// lose to.
    static func merge(rollout: ProviderSignals, live: ProviderSignals?) -> ProviderSignals {
        var reading = rollout
        guard let live else { return reading }
        reading.limitsState = live.limitsState
        reading.resets = live.resets
        guard let observedAt = live.limitsObservedAt, !live.windows.isEmpty else {
            return reading
        }
        guard rollout.limitsObservedAt.map({ observedAt > $0 }) ?? true else { return reading }
        reading.windows = live.windows
        reading.limitsObservedAt = observedAt
        reading.credits = live.credits ?? rollout.credits
        reading.plan = live.plan ?? rollout.plan
        // The identity stays the tail's, which reads `auth.json` and therefore
        // knows the organisation the usage reply does not carry. Taking the
        // reply's instead cost the row its organisation on every poll — the
        // same account, named by the half that knows less about it.
        reading.account = rollout.account ?? live.account
        return reading
    }

    /// One entry per account Sissy can read, the signed-in one included.
    ///
    /// Published whatever its count, a lone reading included: whether a picker
    /// is drawn is the panel's decision and it is taken against this list, so
    /// withholding the only entry would withhold it exactly where a second
    /// account has just been linked and the first has nothing to compare
    /// against.
    ///
    /// The signed-in entry carries that account's *own* reading — the turns
    /// with its own poll over them — rather than whatever the row settled on.
    /// Where the row falls back to a lone linked account, those are different
    /// readings and belonging to different accounts is the whole point.
    static func perAccount(
        own: ProviderSignals,
        signedIn: CodexUsageSource?,
        readers: [CodexUsageSource],
        links: [String: CodexAccountLink]
    ) -> [AccountSignals] {
        var entries: [AccountSignals] = []
        let signedInID = signedIn?.observedAccount
        if let signedInID {
            entries.append(
                AccountSignals(
                    id: signedInID,
                    account: own.account,
                    plan: own.plan,
                    planTier: own.planTier,
                    windows: own.windows,
                    credits: own.credits,
                    resets: own.resets,
                    limitsState: own.limitsState,
                    limitsObservedAt: own.limitsObservedAt,
                    isSignedIn: true))
        }
        for reader in readers {
            guard let id = reader.account, id != signedInID else { continue }
            let signals = reader.currentSignals()
            let link = links[id]
            entries.append(
                AccountSignals(
                    id: id,
                    account: signals.account
                        ?? ProviderAccount(
                            email: link?.identity.email,
                            organization: link?.workspace?.name),
                    plan: signals.plan ?? link?.identity.plan,
                    planTier: nil,
                    windows: signals.windows,
                    credits: signals.credits,
                    resets: signals.resets,
                    limitsState: signals.limitsState,
                    limitsObservedAt: signals.limitsObservedAt,
                    isSignedIn: false))
        }
        return entries.sorted { lhs, rhs in
            (lhs.isSignedIn ? 0 : 1, lhs.id) < (rhs.isSignedIn ? 0 : 1, rhs.id)
        }
    }
}
