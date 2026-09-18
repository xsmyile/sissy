import Foundation

/// What a session log line reports about agents, as opposed to about tokens.
///
/// Two kinds rather than one, because they are two different questions and a
/// single counter answers neither. A **session** is a CLI a person started; an
/// **agent** is a sub-agent that CLI spawned to do part of the work on its
/// own. Measured 2026-09-18 over 30 days of `~/.claude/projects`, 442 sessions
/// spawned 189 agents — one number is how often the user sat down, the other
/// how much of the work was delegated, and their sum is neither.
enum AgentActivityKind: String, Codable, Sendable, CaseIterable {
    case sessionStarted
    case agentSpawned
}

/// One observation an adapter read off a line.
///
/// Carries the instant rather than the day. Bucketing belongs to
/// `LocalUsageProvider` for the reason a `UsageEvent`'s does: two adapters
/// resolving a calendar day apart would file a turn and the agent that ran it
/// on different days.
struct AgentActivityEvent: Sendable, Equatable {
    let timestamp: Date
    let kind: AgentActivityKind
}

/// The dedup keys agent counting claims, namespaced away from the token keys
/// sharing the ledger with them.
///
/// The ledger is the one `SourceAdapter.event(from:seen:activity:)` already
/// takes: it is persisted in the snapshot and trimmed by day, which is exactly
/// what a count needs — a `tool_use` block whose assistant line is rewritten
/// while the answer streams must be counted once, and once across a relaunch
/// that lands between two copies of it.
///
/// A prefix rather than a second ledger because a second one is a second thing
/// to persist, trim and reconcile for a value that wants the identical
/// lifetime. The prefixes cannot collide with either adapter's own keys: the
/// Claude adapter keys on a request id and the Codex one on a byte offset, and
/// neither shape starts with a word and a colon.
enum AgentActivityKey {
    static func agent(_ id: String) -> String { "agent:\(id)" }
    static func session(_ id: String) -> String { "session:\(id)" }
}

/// One provider's agent counters for one day.
///
/// Kept beside the token totals rather than inside them: a count is not a row
/// per model per project, it is one pair of numbers for the provider's whole
/// day, and folding it into the rows would make it depend on which model
/// happened to answer.
struct AgentCounts: Codable, Equatable, Sendable {
    var sessions: Int
    var agents: Int

    init(sessions: Int = 0, agents: Int = 0) {
        self.sessions = sessions
        self.agents = agents
    }

    /// Nothing observed, which is what a day with no file, and a file written
    /// before the archive carried these, both read as.
    static let none = Self()

    var isEmpty: Bool { self == .none }

    mutating func record(_ kind: AgentActivityKind) {
        switch kind {
        case .sessionStarted: sessions += 1
        case .agentSpawned: agents += 1
        }
    }

    mutating func add(_ other: Self) {
        sessions += other.sessions
        agents += other.agents
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        var out = lhs
        out.add(rhs)
        return out
    }
}
