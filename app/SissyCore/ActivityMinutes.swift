import Foundation

/// The minutes of one local day in which something happened, as a bitmap.
///
/// **A set of minutes rather than a list of intervals, because the tail reads
/// files newest first and a day's turns therefore arrive out of order.** An
/// interval list has to be spliced on every insert and gives a different
/// answer depending on which file was read first; a set is order-independent
/// and idempotent, which is exactly what a day the archive rewrites *whole*
/// needs — a cold re-scan ORs the same minutes back in rather than doubling
/// them, for the same reason a re-derived day replaces its file.
///
/// The minute is also the grain the reading is *defined* at, not a rounding of
/// something finer: a day is the minutes work landed in, and a duration is how
/// many of them the blocks cover. Measured 2026-09-19 across 12 days of
/// `~/.claude/projects`, that lands within 2–27 minutes of summing the exact
/// gaps between consecutive turns — a median of 7 minutes on days of 12 hours,
/// about 1% — and it costs 188 bytes a day where the instants cost 80 KB.
///
/// Capacity is `minutesPerDay` rather than 1440 because a local day is 1380 or
/// 1500 minutes across a daylight-saving change, and the index is minutes
/// since that day's own start.
struct ActivityMinutes: Equatable, Sendable {
    /// The longest a local day can be, which is the 25 hours a backward
    /// daylight-saving change makes of one.
    static let minutesPerDay = 1500
    private static let bitsPerByte = 8

    private var bits: [UInt8] = []

    init() {}

    init(minutes: some Sequence<Int>) {
        for minute in minutes { insert(minute) }
    }

    /// Records a minute, growing the storage to reach it. Out of range is
    /// dropped rather than clamped: a clamp would file a turn the calendar
    /// says is on another day into this one's last minute.
    mutating func insert(_ minute: Int) {
        guard minute >= 0, minute < Self.minutesPerDay else { return }
        let byte = minute / Self.bitsPerByte
        if bits.count <= byte { bits.append(contentsOf: repeatElement(0, count: byte - bits.count + 1)) }
        bits[byte] |= 1 << UInt8(minute % Self.bitsPerByte)
    }

    func contains(_ minute: Int) -> Bool {
        guard minute >= 0 else { return false }
        let byte = minute / Self.bitsPerByte
        guard byte < bits.count else { return false }
        return bits[byte] & (1 << UInt8(minute % Self.bitsPerByte)) != 0
    }

    var isEmpty: Bool { bits.allSatisfy { $0 == 0 } }

    var count: Int { bits.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Every minute recorded, ascending.
    var minutes: [Int] {
        var out: [Int] = []
        for (index, byte) in bits.enumerated() where byte != 0 {
            for bit in 0..<Self.bitsPerByte where byte & (1 << UInt8(bit)) != 0 {
                out.append(index * Self.bitsPerByte + bit)
            }
        }
        return out
    }

    mutating func formUnion(_ other: Self) {
        if bits.count < other.bits.count {
            bits.append(contentsOf: repeatElement(0, count: other.bits.count - bits.count))
        }
        for (index, byte) in other.bits.enumerated() { bits[index] |= byte }
    }

    func union(_ other: Self) -> Self {
        var out = self
        out.formUnion(other)
        return out
    }

    /// Runs of recorded minutes, each separated from the next by more than
    /// `gap` idle minutes. A lone minute is a block of one.
    func blocks(separatedByMoreThan gap: Int) -> [ClosedRange<Int>] {
        let recorded = minutes
        guard let first = recorded.first else { return [] }
        var out: [ClosedRange<Int>] = []
        var start = first
        var previous = first
        for minute in recorded.dropFirst() {
            if minute - previous > gap {
                out.append(start...previous)
                start = minute
            }
            previous = minute
        }
        out.append(start...previous)
        return out
    }

    /// How many minutes those blocks cover, which is what a duration is.
    func coveredMinutes(separatedByMoreThan gap: Int) -> Int {
        blocks(separatedByMoreThan: gap).reduce(0) { $0 + $1.count }
    }
}

extension ActivityMinutes: Codable {
    /// Base64 of the bitmap with its trailing empty bytes dropped, so a day
    /// that stopped at lunch costs half of one that ran to midnight.
    init(from decoder: Decoder) throws {
        let encoded = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "activity minutes are not base64"))
        }
        let capacity = (Self.minutesPerDay + Self.bitsPerByte - 1) / Self.bitsPerByte
        bits = Array(data.prefix(capacity))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let trimmed = bits.reversed().drop { $0 == 0 }.reversed()
        try container.encode(Data(trimmed).base64EncodedString())
    }
}

/// How much of one day a provider was working, and how much of that its
/// sub-agents were.
///
/// **A block is a run of work and the gap is what ends it.** Measured
/// 2026-09-19 over 12 days, the span from a day's first turn to its last is
/// useless — 23h59 on two of those days, because a long agent run straddles
/// the night — while the minutes the blocks cover land between 5 and 13 hours
/// and track the day somebody would describe. The threshold barely matters,
/// which is why it is decided here rather than offered as a setting: 10
/// against 15 minutes differ by 1.6% on the widest of those days and under 5%
/// on nine of the twelve.
///
/// **The delegated half is measured the same way rather than by counting the
/// minutes a sub-agent's turn landed in**, so the page carries one rule and
/// not two: it is the minutes covered by the blocks of the sub-agents' own
/// turns. Measured across the same 12 days it is 11–28% of the day.
///
/// What is deliberately *not* here is the split between the minutes a person
/// drove and the minutes the CLI drove itself. It cannot be read: a session a
/// program started writes the same `user` message a person typing does, and
/// telling them apart means reading the prompt's text, which is the most
/// personal thing in those logs. Measured 2026-09-17 on this machine, 482 of
/// the day's `user` lines were plain text and most were a tool asking Claude
/// Code for a branch name.
struct AgentActivityDay: Equatable, Sendable, Codable {
    /// Idle minutes that end a block. Ten, and see the type's own note for why
    /// it is a constant and not a setting.
    static let idleGapMinutes = 10

    /// Minutes a billed turn landed in.
    var turns: ActivityMinutes
    /// The same, for turns a sub-agent spent rather than the session itself.
    /// A subset of `turns` by construction, so its blocks nest inside theirs.
    var delegated: ActivityMinutes
    /// How long the day's longest turn ran, as the CLI timed it from the
    /// prompt to the end of the answer. Nil where no turn reported one, which
    /// is every day written before this was read and is not a turn of zero.
    ///
    /// A reading of the same turns the minutes are, and beside them for that
    /// reason: it belongs to the provider's day and to no model, and folding
    /// it here is what carries it through the snapshot, the archive and the
    /// slice without a sixth map. The maximum rather than a list, because a
    /// maximum is idempotent — Claude Code writes the line once per turn and
    /// a forked Codex rollout replays its parent's, and a re-read of either
    /// lands on the same figure.
    var longestTurnMilliseconds: Int?

    init(
        turns: ActivityMinutes = .init(), delegated: ActivityMinutes = .init(),
        longestTurnMilliseconds: Int? = nil
    ) {
        self.turns = turns
        self.delegated = delegated
        self.longestTurnMilliseconds = longestTurnMilliseconds
    }

    /// Nothing observed, which is what a day with no file and a day written
    /// before the archive carried this both read as.
    static let none = Self()

    var isEmpty: Bool { turns.isEmpty && delegated.isEmpty && longestTurnMilliseconds == nil }

    var blocks: [ClosedRange<Int>] { turns.blocks(separatedByMoreThan: Self.idleGapMinutes) }

    var activeMinutes: Int { turns.coveredMinutes(separatedByMoreThan: Self.idleGapMinutes) }

    var delegatedMinutes: Int {
        delegated.coveredMinutes(separatedByMoreThan: Self.idleGapMinutes)
    }

    mutating func record(minute: Int, delegated isDelegated: Bool) {
        turns.insert(minute)
        if isDelegated { delegated.insert(minute) }
    }

    mutating func recordTurn(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        longestTurnMilliseconds = Self.longer(longestTurnMilliseconds, milliseconds)
    }

    mutating func formUnion(_ other: Self) {
        turns.formUnion(other.turns)
        delegated.formUnion(other.delegated)
        longestTurnMilliseconds = Self.longer(
            longestTurnMilliseconds, other.longestTurnMilliseconds)
    }

    /// The longer of two readings, where nil is no reading rather than zero.
    static func longer(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): max(lhs, rhs)
        default: lhs ?? rhs
        }
    }

    /// Two providers' readings of one day, as one.
    ///
    /// A union rather than a sum, and it is not a refinement: measured
    /// 2026-09-19, Codex runs almost entirely inside the minutes Claude Code
    /// is already working in, so summing the two says 12h40 on a day the union
    /// puts at 11h15.
    func union(_ other: Self) -> Self {
        var out = self
        out.formUnion(other)
        return out
    }

    /// Which minute of its local day an instant falls in, which is the index
    /// everything here is keyed by.
    static func minute(of instant: Date, calendar: Calendar = .current) -> Int {
        Int(instant.timeIntervalSince(calendar.startOfDay(for: instant)) / secondsPerMinute)
    }

    private static let secondsPerMinute: TimeInterval = 60
}

/// What a stretch of days worked out to, which is the only shape a window
/// wider than a day can carry.
///
/// Minutes rather than the bitmaps themselves: two days' bitmaps cannot be
/// unioned — they index different days — so a window is a sum, and the sum is
/// taken after each day's providers have been unioned into one.
struct ActivityTotals: Equatable, Sendable {
    var activeMinutes: Int
    var delegatedMinutes: Int
    /// How many separate sittings those minutes came in.
    ///
    /// Carried rather than derived, because past today there is nothing left
    /// to derive it from: the bitmaps of two days cannot be unioned — they
    /// index different days — so a window's blocks are the sum of each day's,
    /// counted while that day's own bitmap is still in hand. Without it the
    /// page could only say `0 blocks` for every window but today, which is the
    /// false zero this panel refuses everywhere else.
    var blocks: Int
    /// The longest turn any of those days held, nil where none reported one.
    var longestTurnMilliseconds: Int?

    init(
        activeMinutes: Int = 0, delegatedMinutes: Int = 0, blocks: Int = 0,
        longestTurnMilliseconds: Int? = nil
    ) {
        self.activeMinutes = activeMinutes
        self.delegatedMinutes = delegatedMinutes
        self.blocks = blocks
        self.longestTurnMilliseconds = longestTurnMilliseconds
    }

    init(_ day: AgentActivityDay) {
        self.init(
            activeMinutes: day.activeMinutes,
            delegatedMinutes: day.delegatedMinutes,
            blocks: day.blocks.count,
            longestTurnMilliseconds: day.longestTurnMilliseconds)
    }

    static let none = Self()

    var isEmpty: Bool { self == .none }

    mutating func add(_ other: Self) {
        activeMinutes += other.activeMinutes
        delegatedMinutes += other.delegatedMinutes
        blocks += other.blocks
        longestTurnMilliseconds = AgentActivityDay.longer(
            longestTurnMilliseconds, other.longestTurnMilliseconds)
    }
}
