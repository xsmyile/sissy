import XCTest

@testable import Sissy

final class RateLogTests: XCTestCase {
    private let start = SampleTime(
        wall: Date(timeIntervalSince1970: 1_790_000_000), instant: .now)

    private let perSecond: (Int, Int, TimeInterval) -> Double? = { from, to, seconds in
        seconds > 0 ? Double(to - from) / seconds : nil
    }

    private func log(_ steps: [(Int, SampleTime)], next: LiveCadence = .background) -> RateLog<Int, Double> {
        var log = RateLog<Int, Double>()
        for (counter, time) in steps { log.record(counter, at: time, next: next, rate: perSecond) }
        return log
    }

    func testTheGapIsMeasuredOnTheInstants() {
        let log = log([(0, start), (100, start + 5)])
        XCTAssertEqual(log.points.map(\.rate), [20])
    }

    /// The wall clock set an hour forward between two samples five seconds
    /// apart: the step is inside the bound on the wall and the rate would
    /// read as the counters' change over 3,605 seconds.
    func testAWallClockSetForwardDoesNotScaleTheRate() {
        let jumped = SampleTime(wall: (start + 3_605).wall, instant: (start + 5).instant)
        let log = log([(0, start), (100, jumped)])
        XCTAssertEqual(log.points.map(\.rate), [20])
        XCTAssertEqual(log.points.map(\.at), [jumped.wall])
    }

    /// The wall clock set back reads as no time passed, or as time reversed;
    /// the instants say five seconds went by.
    func testAWallClockSetBackDoesNotRestartTheSeries() {
        let jumped = SampleTime(wall: (start - 60).wall, instant: (start + 5).instant)
        let log = log([(0, start), (100, jumped)])
        XCTAssertEqual(log.points.map(\.rate), [20])
    }

    /// A sleep the wall clock is set across, and the instants are not fooled
    /// by: the wall reads five seconds where the Mac was gone for minutes.
    func testAGapOnTheInstantsRestartsTheSeriesWhateverTheWallSays() {
        let slept = SampleTime(wall: (start + 5).wall, instant: (start + 600).instant)
        let log = log([(0, start), (100, slept)])
        XCTAssertEqual(log.points, [])
    }

    func testTheBoundIsTheCadencesOwn() {
        let atBound = log([(0, start), (100, start + LiveCadence.background.maximumGap)])
        XCTAssertEqual(atBound.points.count, 1)
        let past = log([(0, start), (100, start + LiveCadence.background.maximumGap + 1)])
        XCTAssertEqual(past.points, [])
    }

    func testTheWindowIsCountedOnTheWallClock() {
        let steps = (0...30).map { (Int($0) * 100, start + TimeInterval($0) * 5) }
        let log = log(steps)
        XCTAssertEqual(log.points.first?.at, (start + 150 - LiveCadence.window).wall)
        XCTAssertEqual(log.points.count, 25)
    }
}
