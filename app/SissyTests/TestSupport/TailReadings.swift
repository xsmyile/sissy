import Foundation

@testable import Sissy

/// The readings a tail publishes, for a suite that has to wait until the
/// tail has taken a line in rather than for a fixed time.
enum TailReadings {
    /// How long a wait holds out before the reading counts as missed.
    static let deadline: Duration = .seconds(10)

    struct Missed: Error {
        let tokens: Int
    }

    /// A stream of each reading's `totalTokens`, and the callback that feeds
    /// it, to hand to `start`.
    static func stream() -> (AsyncStream<Int>, @Sendable (DayTotals) async -> Void) {
        let (readings, emitted) = AsyncStream.makeStream(of: Int.self)
        return (readings, { today in emitted.yield(today.totalTokens) })
    }

    /// Returns once a reading of at least `tokens` arrives, and throws
    /// `Missed` when none has by `deadline`.
    static func waitUntil(_ readings: AsyncStream<Int>, reach tokens: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await reading in readings where reading >= tokens { return }
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw Missed(tokens: tokens)
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
