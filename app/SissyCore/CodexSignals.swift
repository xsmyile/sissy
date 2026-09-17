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
struct CodexSignals: SourceSignals {
    /// What the tail published, which is also where the day's tokens and the
    /// activity stamp come from. Those are never the readers': a usage reply
    /// carries no spend, and an account the CLI is not signed into has none.
    let rollout: LockedValue<ProviderSignals>
    /// One reader per credential, the CLI's own included. Held behind a lock
    /// because the set changes while the adapter lives — an account linked, an
    /// account forgotten — and read nonisolated because the aggregator asks
    /// while the emitting provider still holds its actor.
    let sources: LockedValue<[CodexUsageSource]>

    func currentSignals() -> ProviderSignals {
        let signedIn = sources.load().first { $0.account == nil }
        return Self.merge(rollout: rollout.load(), live: signedIn?.currentSignals())
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
}
