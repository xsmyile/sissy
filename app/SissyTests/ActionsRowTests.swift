import XCTest

@testable import Sissy

/// The Actions rows the Forge tab draws, built from a reading: pure, a
/// reading in and rows out, on the fixtures `ActionsQuotaTests` measured.
final class ActionsRowTests: XCTestCase {
    private typealias Fixture = ActionsQuotaTests

    func testASpentAllowanceUnderAStoppingBudgetSaysCIStopped() throws {
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([Fixture.quota(overrun: .stops)]),
                now: Fixture.midOctober))
        let row = try XCTUnwrap(block.rows.first)
        XCTAssertTrue(row.stopped)
        XCTAssertEqual(row.state?.hasPrefix("CI stopped until "), true)
        XCTAssertEqual(row.spender, "try-on-buddy · macOS 80%")
        XCTAssertEqual(row.window?.label, "radonforge")
        XCTAssertEqual(block.title, "Actions minutes · October")
    }

    func testAnAllowanceWithRoomSaysNothingUnderTheGauge() throws {
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([Fixture.quota(spent: 3)]),
                now: Fixture.midOctober))
        let row = try XCTUnwrap(block.rows.first)
        XCTAssertNil(row.state)
        XCTAssertFalse(row.stopped)
        XCTAssertEqual(row.window?.percent, 25)
    }

    func testTheOwnerRunningOutFirstLeads() throws {
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([
                    Fixture.quota(spent: 2, id: "obliolabs"), Fixture.quota(spent: 11, id: "radonforge"),
                ]), now: Fixture.midOctober))
        XCTAssertEqual(block.rows.map(\.id), ["radonforge", "obliolabs"])
        XCTAssertEqual(block.rows.map(\.isBinding), [true, false])
    }

    /// 99.6% rounds to a gauge reading 100% and is still not spent.
    func testAnAllowanceJustShortOfFullIsNotSpent() throws {
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([Fixture.quota(spent: 11.952, overrun: .stops)]), now: Fixture.midOctober))
        let row = try XCTUnwrap(block.rows.first)
        XCTAssertEqual(row.window?.percent, 100)
        XCTAssertNil(row.state)
        XCTAssertFalse(row.stopped)
    }

    func testAnOwnerThatRanNothingHasNoRow() {
        XCTAssertNil(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([Fixture.quota(spent: 0)]),
                now: Fixture.midOctober))
    }

    func testAMissingScopeIsSaidEvenWithNoRows() throws {
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([], needsScope: true), now: Fixture.midOctober))
        XCTAssertTrue(block.rows.isEmpty)
        XCTAssertEqual(block.scopeNotice, UsageFormat.actionsNeedsUserScope)
    }

    func testAnUnknownPlanPrintsTheMinutesWithoutAGauge() throws {
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([Fixture.quota(plan: nil)]),
                now: Fixture.midOctober))
        let row = try XCTUnwrap(block.rows.first)
        XCTAssertNil(row.window)
        XCTAssertEqual(row.minutes, "\(564.formatted()) min")
    }

    /// A reading from a month that has ended keeps its row and loses its
    /// figure, the roll-over every limit window is on, and says nothing about
    /// CI having stopped: that was last month.
    func testLastMonthsReadingRollsOver() throws {
        let november = Fixture.october.end.addingTimeInterval(3_600)
        let block = try XCTUnwrap(
            UsagePanelSnapshot.makeActions(
                Fixture.reading([Fixture.quota(overrun: .stops)]),
                now: november))
        let row = try XCTUnwrap(block.rows.first)
        XCTAssertEqual(row.window?.hasRolledOver, true)
        XCTAssertFalse(row.stopped)
        XCTAssertNil(row.state)
    }
}
