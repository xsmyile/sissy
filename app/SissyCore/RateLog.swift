import Foundation

/// A rate, and the moment of the sample that closed the gap it was measured
/// over.
///
/// **Dated rather than counted.** A series fed at two cadences has points five
/// seconds apart and points one second apart, so a sparkline that placed them
/// by index would draw a minute of background as twelve seconds; placed by
/// this time, both kinds sit on one axis, and a hover's age is the point's own.
struct RatePoint<Rate: Sendable & Equatable>: Sendable, Equatable {
    let at: Date
    let rate: Rate
}

/// When a sample was taken, on the two clocks it needs.
///
/// **The wall clock places, the continuous one measures.** `wall` is where a
/// point sits on the axis and what a hover's age is counted from, and it is
/// what NTP or a hand on the clock can move; a step of it inside the gap bound
/// would be taken for an ordinary interval and scale a rate by a step nobody
/// took. `instant` is on `ContinuousClock`, which no adjustment moves and
/// which keeps counting while the Mac sleeps, so a sleep still reads as the
/// gap it is; `SuspendingClock` would fold it away.
struct SampleTime: Sendable, Equatable {
    let wall: Date
    let instant: ContinuousClock.Instant

    static var now: Self { Self(wall: Date(), instant: .now) }

    /// The same moment `seconds` later on both clocks, which is how a test
    /// drives them together.
    static func + (time: Self, seconds: TimeInterval) -> Self {
        Self(wall: time.wall + seconds, instant: time.instant + .seconds(seconds))
    }

    static func - (time: Self, seconds: TimeInterval) -> Self {
        time + -seconds
    }
}

/// The last `LiveCadence.window` of rates a monitor measured, and the counters
/// the next one is measured from.
///
/// The arithmetic `NetworkMonitor` and `DiskActivityMonitor` share, so the two
/// sparklines mean the same by two minutes and by a gap. **In memory and
/// nowhere else**: a monitor that stops drops its log, so a switch turned on
/// again starts a new series rather than joining one across minutes nobody
/// sampled.
struct RateLog<Counters: Sendable, Rate: Sendable & Equatable>: Sendable {
    /// The last record: what the next rate is measured from, and the cadence
    /// its gap is judged by.
    private struct Previous: Sendable {
        let counters: Counters
        let at: ContinuousClock.Instant
        let next: LiveCadence
    }

    private var previous: Previous?
    /// Oldest first, none older than `LiveCadence.window` before the latest
    /// record.
    private(set) var points: [RatePoint<Rate>] = []

    /// Measures the rate since the last record, appends it, and drops what
    /// has aged out of the window.
    ///
    /// `next` is the cadence the monitor waits at before the record after
    /// this one, and it is what that record's gap is judged by: the first
    /// sample of a page just opened comes at most five seconds after a
    /// background one, which is one step of the cadence it was waited at, and
    /// judging it by the one-second pace it is taken at would drop the series
    /// the background kept for that page.
    ///
    /// **A gap beyond `LiveCadence.maximumGap` restarts the series**, and so
    /// does a step `rate` has nothing to measure in: the next rate is
    /// measured from these counters, as a monitor started afresh would. The
    /// gap is the `SampleTime.instant`s' difference, so a wall clock that was
    /// set forward or back between two samples changes neither the rate nor
    /// whether the series goes on.
    mutating func record(
        _ counters: Counters, at now: SampleTime, next: LiveCadence,
        rate: (Counters, Counters, TimeInterval) -> Rate?
    ) {
        if let previous {
            let gap = (now.instant - previous.at) / .seconds(1)
            if gap <= previous.next.maximumGap, let measured = rate(previous.counters, counters, gap) {
                points.append(RatePoint(at: now.wall, rate: measured))
                let oldest = now.wall.addingTimeInterval(-LiveCadence.window)
                points.removeAll { $0.at < oldest }
            } else {
                points = []
            }
        }
        previous = Previous(counters: counters, at: now.instant, next: next)
    }
}
