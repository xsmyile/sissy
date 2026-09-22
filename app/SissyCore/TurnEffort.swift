import Foundation

/// Which model ran at which effort, which is the pair the split is kept at.
///
/// A pair rather than a third key on `UsageHistoryRow`: that row is
/// `(model, project)` and `isCoveredBy` holds every row naming a project to
/// its own key, so rows split by effort as well would not cover the files
/// already on disk and every day a new build re-derived would freeze instead
/// of being rewritten. Kept beside the rows, the dimension costs the archive
/// `models × efforts` entries a day — measured 2026-09-22, 3 and 2 models
/// against 3 and 4 efforts — where a third key would have cost
/// `models × projects × efforts`.
struct EffortKey: Hashable, Sendable {
    let model: String
    /// The vendor's own word, and **nil for spend the line named no effort
    /// for**.
    ///
    /// Nil is a key rather than a reason to drop the event, because the block
    /// this feeds sits under the model pills and has to reach them: an event
    /// left out here still counts in the rows, so a model with nine tagged
    /// turns and one untagged would read `high 100%` over a fraction of what
    /// the pill above it says. It is reachable — Codex names the effort on a
    /// `turn_context` a resumed reader is past, so the first launch after an
    /// upgrade has turns no `fileEfforts` entry covers yet — and it is the one
    /// shape that makes "a model's efforts add up to what that model spent"
    /// true by construction rather than by the vendor's good behaviour.
    let effort: String?
}

/// What one model spent at one effort: the turns it took and what they came
/// to.
///
/// **Both, because they answer different halves of one question.** The turns
/// are what an effort is set per, so they are the honest count of how often a
/// setting was used; the money is what makes the reading comparable with the
/// model pills above it on the same page, which is where a reader is asking
/// "what is the high effort costing me". A count of events beside a block of
/// money answers neither.
struct EffortTotals: Sendable, Equatable {
    var turns: Int = 0
    var totals: UsageHistoryTotals = .init()

    var tokens: Int { totals.totalTokens }
    var cost: Decimal { totals.cost }

    /// Folds one event in: its spend always, and a turn only where it began
    /// one. `UsageEvent.startsTurn` carries why the two are asked separately.
    mutating func record(_ event: UsageEvent) {
        if event.startsTurn { turns += 1 }
        totals.add(event)
    }

    mutating func add(_ other: Self) {
        turns += other.turns
        totals.add(other.totals)
    }
}

/// One `(model, effort)` pair as a surface reads it.
///
/// The effort is the vendor's own word, unmapped. Measured 2026-09-22 over a
/// 14-day pass of both trees, Claude Code wrote `xhigh`, `high`, `medium` and
/// `low` while Codex wrote `ultra`, `xhigh`, `high` and `medium`: mostly the
/// same words, with `ultra` one vendor's alone. Neither publishes what its
/// ladder means against the other's, so a translation onto a common scale
/// would be Sissy's invention — which is also why this is read on a provider's
/// own page and never summed across two.
struct EffortSplit: Sendable, Equatable, Identifiable {
    let key: EffortKey
    let totals: EffortTotals

    var model: String { key.model }
    /// Nil where the lines behind this spend named no effort. `EffortKey`
    /// carries why that is a bucket rather than a dropped event.
    var effort: String? { key.effort }
    var turns: Int { totals.turns }
    var tokens: Int { totals.tokens }
    var cost: Decimal { totals.cost }

    var id: String { "\(key.model)\u{1F}\(key.effort ?? "")" }

    init(key: EffortKey, totals: EffortTotals) {
        self.key = key
        self.totals = totals
    }

    init(model: String, effort: String?, totals: EffortTotals) {
        self.init(key: EffortKey(model: model, effort: effort), totals: totals)
    }
}

extension Array where Element == EffortSplit {
    /// The same pairs summed across whatever they were collected over — the
    /// days of a window, or a day and the live reading of today.
    func summed(with other: [EffortSplit]) -> [EffortSplit] {
        var out: [EffortKey: EffortTotals] = [:]
        for split in self + other { out[split.key, default: .init()].add(split.totals) }
        return out.map { EffortSplit(key: $0.key, totals: $0.value) }
    }
}
