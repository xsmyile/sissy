import Foundation

/// How many turns a provider ran at each effort, for one day.
///
/// Both CLIs write the effort on a line the tail already parses — Claude Code
/// at the top level of the assistant line it bills, Codex in the
/// `turn_context` payload it names the model in — so this costs no new file,
/// no second read and no permission. `perTurnEffort` is the field that looks
/// right and is not: measured 2026-09-22 on this machine it was null on 3096
/// of 3106 assistant lines, where `effort` was set on all of them.
///
/// **Turns rather than tokens.** An effort is a setting a turn runs under, not
/// a rate, so it changes no cost and splits no spend; the section it is drawn
/// in counts events — sessions, agents — and this is the third count of the
/// same turns.
///
/// **The vendor's own word, unmapped.** Measured 2026-09-22 over a 14-day
/// backfill of both trees, Claude Code wrote `xhigh`, `high`, `medium` and
/// `low` and Codex wrote `ultra`, `xhigh`, `high` and `medium`: mostly the
/// same words, and `ultra` is one vendor's alone. Neither publishes what its
/// ladder means against the other's, so a translation onto a common scale
/// would be Sissy's invention rather than either vendor's reading.
struct EffortCounts: Codable, Equatable, Sendable {
    /// Turns per effort. A key only ever exists once a turn has been counted
    /// under it, so a zero is not representable: an effort nothing ran at is
    /// absent, which is the same answer the archive gives for a day it holds
    /// no file for.
    private(set) var turns: [String: Int]

    init(_ turns: [String: Int] = [:]) {
        self.turns = turns.filter { $0.value > 0 }
    }

    /// Nothing counted, which is what a provider naming no effort, and a day
    /// written before this shipped, both read as.
    static let none = Self()

    var isEmpty: Bool { turns.isEmpty }

    /// Turns counted across every effort, which is the denominator a share is
    /// taken of. Deliberately not the window's turns: a provider that names no
    /// effort contributes none, and dividing by a total that included its
    /// turns would make every other pill read short.
    var total: Int { turns.values.reduce(0, +) }

    mutating func record(_ effort: String) {
        turns[effort, default: 0] += 1
    }

    mutating func add(_ other: Self) {
        for (effort, count) in other.turns { turns[effort, default: 0] += count }
    }

    /// Two readings of the same day folded to the higher of the two per
    /// effort, which is `AgentCounts`' rule and holds for the same reason: a
    /// count can only ever be under-observed, so a run that started at noon
    /// must not write its afternoon over a file that holds the whole day.
    func merging(_ other: Self) -> Self {
        var folded = turns
        for (effort, count) in other.turns {
            folded[effort] = max(folded[effort] ?? 0, count)
        }
        return Self(folded)
    }

    /// Busiest first, ties by the vendor's word, which is the order the pills
    /// are drawn and folded in.
    var ordered: [EffortShare] {
        turns
            .map { EffortShare(effort: $0.key, turns: $0.value) }
            .sorted {
                $0.turns == $1.turns ? $0.effort < $1.effort : $0.turns > $1.turns
            }
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([String: Int].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(turns)
    }
}

/// One effort's share of a window, as the pill row reads it.
struct EffortShare: Equatable, Sendable, Identifiable {
    let effort: String
    let turns: Int

    var id: String { effort }
}
