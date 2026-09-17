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
        var reading = Self.merge(
            rollout: rollout.load(),
            live: Self.rowReading(signedIn: signedIn, linked: readers.filter { $0.account != nil }))
        reading.accounts = Self.perAccount(
            reading, signedIn: signedIn, readers: readers, links: links.load())
        return reading
    }

    /// Which reading the provider's own row shows.
    ///
    /// The CLI's, whenever it has one — that is the account whose future spend
    /// lands in the day beside it. Failing that, a lone linked account, which
    /// is the only answer there is on a Mac whose `codex` is signed out or has
    /// never run. More than one and there is a choice to get wrong, so the row
    /// keeps the CLI's own answer, empty as it is, and the accounts below it
    /// say the rest.
    static func rowReading(
        signedIn: CodexUsageSource?, linked: [CodexUsageSource]
    ) -> ProviderSignals? {
        let own = signedIn?.currentSignals()
        if let own, own.limitsObservedAt != nil { return own }
        guard linked.count == 1 else { return own }
        return linked[0].currentSignals()
    }

    /// The tail's reading with the live one laid over it, or not, by stamp.
    ///
    /// The live reader's `limitsState` is taken whichever reading wins, and it
    /// is the only field that crosses that line. A state is the answer to "why
    /// is there nothing newer", which is a question only the reader that tried
    /// can answer — the tail never fails, it simply has nothing to add until
    /// the next turn.
    static func merge(rollout: ProviderSignals, live: ProviderSignals?) -> ProviderSignals {
        var reading = rollout
        guard let live else { return reading }
        reading.limitsState = live.limitsState
        guard let observedAt = live.limitsObservedAt, !live.windows.isEmpty else {
            return reading
        }
        guard rollout.limitsObservedAt.map({ observedAt > $0 }) ?? true else { return reading }
        reading.windows = live.windows
        reading.limitsObservedAt = observedAt
        reading.credits = live.credits ?? rollout.credits
        reading.plan = live.plan ?? rollout.plan
        reading.account = live.account ?? rollout.account
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
    /// The signed-in entry carries the row's own reading rather than the
    /// reader's, so the two cannot disagree: what the row shows is what that
    /// account's gauge shows, whichever of the tail and the poll produced it.
    static func perAccount(
        _ reading: ProviderSignals,
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
                    account: reading.account,
                    plan: reading.plan,
                    planTier: reading.planTier,
                    windows: reading.windows,
                    credits: reading.credits,
                    limitsState: reading.limitsState,
                    limitsObservedAt: reading.limitsObservedAt,
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
                    limitsState: signals.limitsState,
                    limitsObservedAt: signals.limitsObservedAt,
                    isSignedIn: false))
        }
        return entries.sorted { lhs, rhs in
            (lhs.isSignedIn ? 0 : 1, lhs.id) < (rhs.isSignedIn ? 0 : 1, rhs.id)
        }
    }
}
