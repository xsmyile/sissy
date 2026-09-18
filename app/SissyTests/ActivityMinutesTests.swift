import XCTest

@testable import Sissy

/// The reading itself: which minutes make a block, what a block is worth, and
/// what two providers' readings of one day come to together.
final class ActivityMinutesTests: XCTestCase {
    private let gap = AgentActivityDay.idleGapMinutes

    func testMinutesExactlyTheGapApartStayOneBlock() {
        let minutes = ActivityMinutes(minutes: [0, gap])
        XCTAssertEqual(minutes.blocks(separatedByMoreThan: gap), [0...gap])
    }

    func testMinutesFurtherApartThanTheGapAreTwoBlocks() {
        let minutes = ActivityMinutes(minutes: [0, gap + 1])
        XCTAssertEqual(minutes.blocks(separatedByMoreThan: gap), [0...0, (gap + 1)...(gap + 1)])
    }

    /// A turn nothing followed is still a minute somebody worked.
    func testALoneMinuteIsABlockOfOne() {
        let minutes = ActivityMinutes(minutes: [742])
        XCTAssertEqual(minutes.coveredMinutes(separatedByMoreThan: gap), 1)
    }

    /// The whole reason this is a set: the tail reads files newest first, so a
    /// day's turns arrive in no particular order and the same line can be read
    /// again by a cold scan.
    func testTheSameMinutesInAnyOrderGiveTheSameReading() {
        let forwards = ActivityMinutes(minutes: [1, 2, 3, 40, 41])
        let backwards = ActivityMinutes(minutes: [41, 3, 40, 2, 1, 3, 40])
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(
            forwards.coveredMinutes(separatedByMoreThan: gap),
            backwards.coveredMinutes(separatedByMoreThan: gap))
    }

    /// Out of range is dropped rather than clamped: a clamp would file a turn
    /// the calendar puts on another day into this one's last minute.
    func testAMinuteOutsideTheDayIsNotRecorded() {
        var minutes = ActivityMinutes()
        minutes.insert(ActivityMinutes.minutesPerDay)
        minutes.insert(-1)
        XCTAssertTrue(minutes.isEmpty)
    }

    func testTheBitmapRoundTripsThroughJSON() throws {
        let original = ActivityMinutes(minutes: [0, 7, 8, 599, 1439])
        let decoded = try JSONDecoder().decode(
            ActivityMinutes.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// A day that stopped at lunch must not pay for the evening it never had.
    func testAShortDayEncodesShorterThanALongOne() throws {
        let morning = try JSONEncoder().encode(ActivityMinutes(minutes: [10]))
        let midnight = try JSONEncoder().encode(ActivityMinutes(minutes: [10, 1439]))
        XCTAssertLessThan(morning.count, midnight.count)
    }

    func testDelegatedMinutesAreMeasuredByTheSameRuleAsTheDay() {
        var day = AgentActivityDay.none
        day.record(minute: 0, delegated: false)
        day.record(minute: 5, delegated: true)
        day.record(minute: 9, delegated: true)
        XCTAssertEqual(day.activeMinutes, 10)
        XCTAssertEqual(day.delegatedMinutes, 5)
    }

    /// Measured 2026-09-19: Codex runs almost entirely inside the minutes
    /// Claude Code is already working in, so a day that summed the two rows
    /// read 12h40 where the union put it at 11h15.
    /// A window wider than today has no bitmap to count blocks from — two
    /// days' cannot be unioned — so the count is summed while each day's is
    /// still in hand. Without it the page said `0 blocks` for every window but
    /// today, which is a reading of none where there had been no reading.
    func testBlocksSurviveBeingSummedAcrossDays() {
        var week = ActivityTotals.none
        week.add(ActivityTotals(AgentActivityDay(turns: ActivityMinutes(minutes: [0, 600]))))
        week.add(ActivityTotals(AgentActivityDay(turns: ActivityMinutes(minutes: [60]))))
        XCTAssertEqual(week.blocks, 3)
        XCTAssertEqual(week.activeMinutes, 3)
    }

    func testTwoProvidersInTheSameMinutesAreOneDayNotTwo() {
        let claude = AgentActivityDay(turns: ActivityMinutes(minutes: Array(0...59)))
        let codex = AgentActivityDay(turns: ActivityMinutes(minutes: Array(30...59)))
        XCTAssertEqual(claude.activeMinutes + codex.activeMinutes, 90)
        XCTAssertEqual(claude.union(codex).activeMinutes, 60)
    }

    /// A local day is 23 or 25 hours across a daylight-saving change, so the
    /// index is minutes since that day's own start and the bitmap is sized for
    /// the longer of the two. Rome, because that is a zone that has them.
    func testADaylightSavingDayFitsItsOwnLastMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        for (month, day, length) in [(3, 29, 1380), (10, 25, 1500), (9, 17, 1440)] {
            var components = DateComponents()
            components.year = 2026
            components.month = month
            components.day = day
            components.timeZone = calendar.timeZone
            let start = try XCTUnwrap(calendar.date(from: components))
            let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            XCTAssertEqual(Int(next.timeIntervalSince(start) / 60), length)

            let last = next.addingTimeInterval(-60)
            let index = AgentActivityDay.minute(of: last, calendar: calendar)
            XCTAssertEqual(index, length - 1)

            var minutes = ActivityMinutes()
            minutes.insert(index)
            XCTAssertTrue(minutes.contains(index), "the last minute of a \(length)-minute day")
        }
    }

    func testTheMinuteIndexIsMeasuredFromTheDaysOwnStart() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 17
        components.hour = 14
        components.minute = 30
        let instant = try XCTUnwrap(Calendar.current.date(from: components))
        XCTAssertEqual(AgentActivityDay.minute(of: instant), 14 * 60 + 30)
    }
}

/// What the archive does with the shape when two readings of one day meet.
final class ActivityArchiveTests: XCTestCase {
    private func day(_ activity: AgentActivityDay?) -> UsageHistoryDay {
        UsageHistoryDay(
            day: "2026-09-17", provider: ProviderID.claudeCode, updatedAt: Date(),
            totals: [:], agents: nil, activity: activity)
    }

    /// A run that started at noon saw the afternoon and not the morning. The
    /// union is what keeps the morning, exactly as the counts keep the higher
    /// of the two.
    func testAPartialRunUnionsIntoTheDayRatherThanReplacingIt() {
        let morning = day(AgentActivityDay(turns: ActivityMinutes(minutes: [540, 545])))
        let afternoon = AgentActivityDay(turns: ActivityMinutes(minutes: [840, 845]))
        let merged = morning.merging(counts: nil, activity: afternoon)
        XCTAssertEqual(merged.activity?.blocks.count, 2)
        XCTAssertEqual(merged.activity?.activeMinutes, 12)
    }

    /// A day neither reading measured carries no shape at all, so the page can
    /// draw a dash rather than claim nobody worked.
    func testADayNeitherReadingMeasuredCarriesNoShape() {
        XCTAssertNil(day(nil).merging(counts: nil, activity: nil).activity)
        XCTAssertNil(day(.none).activity)
    }

    func testReattributionKeepsTheShape() {
        let recorded = AgentActivityDay(turns: ActivityMinutes(minutes: [600]))
        XCTAssertEqual(day(recorded).reattributed(by: { _ in nil }).activity, recorded)
    }

    func testTheShapeRoundTripsThroughTheDayFile() throws {
        let recorded = AgentActivityDay(
            turns: ActivityMinutes(minutes: [10, 11, 600]),
            delegated: ActivityMinutes(minutes: [11]))
        let decoded = try JSONDecoder().decode(
            UsageHistoryDay.self, from: JSONEncoder().encode(day(recorded)))
        XCTAssertEqual(decoded.activity, recorded)
    }

    /// A file written before the field existed decodes as a day nothing was
    /// measured on rather than failing to decode.
    func testADayFileWrittenBeforeTheFieldStillDecodes() throws {
        let json = """
            {"schemaVersion":1,"day":"2026-09-17","provider":"claude-code",
            "updatedAt":"2026-09-17T12:00:00Z","models":[]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageHistoryDay.self, from: Data(json.utf8))
        XCTAssertNil(decoded.activity)
    }
}

/// What the export carries, and at which grain.
final class ActivityExportTests: XCTestCase {
    private func day(_ provider: String, _ activity: AgentActivityDay?) -> UsageHistoryDay {
        UsageHistoryDay(
            day: "2026-09-17", provider: provider, updatedAt: Date(), totals: [:],
            agents: nil, activity: activity)
    }

    func testOneRowPerDayAndProvider() {
        let csv = UsageHistoryExport.activityCSV([
            day(ProviderID.claudeCode, AgentActivityDay(turns: ActivityMinutes(minutes: [0, 5]))),
            day(ProviderID.codex, AgentActivityDay(turns: ActivityMinutes(minutes: [3]))),
        ])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "day,provider,active_minutes,delegated_minutes,blocks")
        XCTAssertTrue(lines[1].hasSuffix(",6,0,1"), String(lines[1]))
    }

    /// A day the archive measured nothing for gets no row: a zero in a
    /// spreadsheet is a claim that nobody worked.
    func testADayWithNoShapeContributesNoRow() {
        let csv = UsageHistoryExport.activityCSV([day(ProviderID.claudeCode, nil)])
        XCTAssertEqual(csv.split(separator: "\n").count, 1)
    }
}
