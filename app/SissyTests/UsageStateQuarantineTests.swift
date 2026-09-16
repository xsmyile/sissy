import XCTest

@testable import Sissy

/// What the tail leaves behind when it meets a snapshot it cannot read.
///
/// A quarantined copy is a forensic artifact, and one is kept for that. What
/// it must not be is unbounded: a schema bump quarantines every install's
/// snapshot at once, and nothing used to remove the copies it left.
final class UsageStateQuarantineTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private var snapshotURL: URL {
        UsageStatePersistence.defaultURL(in: stateDir)
    }

    /// One load of a snapshot written by a schema this build does not know.
    /// Each call leaves one copy aside, which is what accumulates.
    private func loadAnUnreadableSnapshot(_ index: Int) throws {
        let body = """
            {"schemaVersion":99,"savedAt":"2026-01-0\(index)T00:00:00Z",\
            "claudeDataDirHash":"x","retainDays":2,"files":[],"dailyTotals":[],\
            "dedupKeysToday":[]}
            """
        try Data(body.utf8).write(to: snapshotURL)
        guard case .invalid = UsageStatePersistence.load(from: snapshotURL) else {
            return XCTFail("a snapshot from an unknown schema should not load")
        }
    }

    private func quarantinedCopies() throws -> [String] {
        let prefix = UsageStatePersistence.quarantinePrefix(for: snapshotURL)
        return try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
            .filter { $0.hasPrefix(prefix) }
    }

    func testTheFirstUnreadableSnapshotIsKeptAside() throws {
        try loadAnUnreadableSnapshot(1)
        XCTAssertEqual(try quarantinedCopies().count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: snapshotURL.path),
            "the snapshot is moved aside, so the next boot cold-scans instead of looping")
    }

    /// Copies an earlier build's schema bumps would have left behind, each a
    /// day older than the last. Written by hand because the real thing stamps
    /// its name with the second it ran in, and a test cannot spend four days
    /// producing them.
    @discardableResult
    private func leaveOlderCopies(_ count: Int) throws -> [URL] {
        let prefix = UsageStatePersistence.quarantinePrefix(for: snapshotURL)
        return try (1...count).map { age in
            let copy = stateDir.appendingPathComponent(
                "\(prefix)schema-mismatch-\(1_700_000_000 + age).json")
            try Data("{}".utf8).write(to: copy)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-86_400 * Double(age))],
                ofItemAtPath: copy.path)
            return copy
        }
    }

    func testQuarantinedCopiesDoNotAccumulate() throws {
        try leaveOlderCopies(4)
        try loadAnUnreadableSnapshot(1)
        XCTAssertEqual(try quarantinedCopies().count, UsageStatePersistence.quarantineKeep)
    }

    func testThePrunedCopiesAreTheOldestOnes() throws {
        let older = try leaveOlderCopies(4)
        let newest = try XCTUnwrap(older.first).lastPathComponent
        let oldest = try XCTUnwrap(older.last).lastPathComponent
        try loadAnUnreadableSnapshot(1)
        let survivors = try quarantinedCopies()
        XCTAssertTrue(
            survivors.contains(newest),
            "the newest copy is the one anybody would open, so it is the one that stays")
        XCTAssertFalse(survivors.contains(oldest))
    }

    func testAFileThisTypeDidNotWriteIsLeftAlone() throws {
        let theirs = stateDir.appendingPathComponent("usage-state.json.backup-by-hand")
        try Data("{}".utf8).write(to: theirs)
        try leaveOlderCopies(4)
        try loadAnUnreadableSnapshot(1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: theirs.path),
            "the state dir is the user's, and nothing here may delete what it did not write")
    }
}
