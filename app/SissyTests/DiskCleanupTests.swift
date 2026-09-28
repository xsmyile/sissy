import XCTest

@testable import Sissy

/// What a cleanup may size and remove, run against a home made in a temporary
/// directory and never against the real one.
final class DiskCleanupTests: XCTestCase {
    private var home: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCleanupTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write(outside.appendingPathComponent("keep.bin"))
    }

    override func tearDownWithError() throws {
        let base = home.deletingLastPathComponent()
        if let paths = FileManager.default.enumerator(atPath: base.path) {
            for case let path as String in paths {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(path).path)
            }
        }
        try FileManager.default.removeItem(at: base)
    }

    private func root(_ target: CleanupTarget = .npm) throws -> URL {
        let url = target.components.reduce(home) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int = 10_000) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func allocated(_ url: URL) -> Int64 {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        return Int64(status.st_blocks) * 512
    }

    private func contents(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private var cleaner: DiskCleaner { DiskCleaner(home: home.path) }

    // MARK: Sizing

    /// The allocated blocks of every entry under the root, a hard-linked file
    /// counted once.
    func testSizeCountsAllocatedBlocksOnceForAHardLink() async throws {
        let root = try root()
        let first = root.appendingPathComponent("a/one.bin")
        let second = root.appendingPathComponent("b/two.bin")
        try write(first)
        try write(second, bytes: 50_000)
        try FileManager.default.linkItem(at: second, to: root.appendingPathComponent("a/link.bin"))
        let expected = [first, second, root.appendingPathComponent("a"), root.appendingPathComponent("b")]
            .map(allocated).reduce(0, +)

        let size = await cleaner.size(of: .npm)

        XCTAssertEqual(size, expected)
        XCTAssertGreaterThan(expected, 60_000)
    }

    func testSizeOfAMissingRootIsZero() async {
        let size = await cleaner.size(of: .derivedData)
        XCTAssertEqual(size, 0)
    }

    /// A symlink is counted as the link it is, never as what it points at.
    func testSizeDoesNotFollowASymlinkOutOfTheRoot() async throws {
        let root = try root()
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let size = await cleaner.size(of: .npm)

        XCTAssertEqual(size, allocated(root.appendingPathComponent("escape")))
        XCTAssertLessThan(size ?? .max, allocated(outside.appendingPathComponent("keep.bin")))
    }

    // MARK: Removal

    /// The directory stays, empty, for the tool that owns it.
    func testCleanRemovesContentsAndKeepsTheRoot() async throws {
        let root = try root()
        try write(root.appendingPathComponent("index-v5/aa/bb/entry"))
        try write(root.appendingPathComponent("content-v2/file"))

        let freed = [
            root.appendingPathComponent("index-v5/aa/bb/entry"),
            root.appendingPathComponent("content-v2/file"),
        ]
        .map(allocated).reduce(0, +)

        let report = await cleaner.clean(.npm)

        XCTAssertEqual(report, CleanupReport(removed: 6, removedBytes: freed))
        XCTAssertEqual(try contents(root), [])
        let remaining = await cleaner.size(of: .npm)
        XCTAssertEqual(remaining, 0)
    }

    /// A symlink inside a root pointing outside is removed as a link, and
    /// what it points at is untouched.
    func testCleanRemovesALinkAndNeverWhatItPointsAt() async throws {
        let root = try root()
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("file-escape"),
            withDestinationURL: outside.appendingPathComponent("keep.bin"))

        let report = await cleaner.clean(.npm)

        XCTAssertEqual(report?.removed, 2)
        XCTAssertEqual(try contents(root), [])
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// The same holds for a link any depth down.
    func testCleanRemovesANestedLinkAndNeverWhatItPointsAt() async throws {
        let root = try root()
        let nested = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("escape"), withDestinationURL: outside)

        let size = await cleaner.size(of: .npm)
        let report = await cleaner.clean(.npm)

        XCTAssertLessThan(size ?? .max, allocated(outside.appendingPathComponent("keep.bin")))
        XCTAssertEqual(report?.removed, 4)
        XCTAssertEqual(report?.isComplete, true)
        XCTAssertEqual(try contents(root), [])
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// A file still linked outside the root is removed from it and frees
    /// nothing, and the other link keeps its contents.
    func testCleanCountsNoBytesForAFileLinkedOutside() async throws {
        let root = try root()
        try FileManager.default.linkItem(
            at: outside.appendingPathComponent("keep.bin"), to: root.appendingPathComponent("shared"))

        let report = await cleaner.clean(.npm)

        XCTAssertEqual(report, CleanupReport(removed: 1))
        XCTAssertEqual(try contents(outside), ["keep.bin"])
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep.bin")).count, 10_000)
    }

    /// A root whose real path is not the one named, here the same directory
    /// under another case, is refused by the real-path check: on a
    /// case-insensitive volume the component opens, and `F_GETPATH` answers
    /// the name on disk.
    func testCleanRefusesARootWhoseRealPathDiffers() async throws {
        let wrongCase = home.appendingPathComponent(".npm/_CACACHE")
        try write(wrongCase.appendingPathComponent("entry"))

        let report = await cleaner.clean(.npm)

        XCTAssertNil(report)
        XCTAssertEqual(try contents(wrongCase), ["entry"])
    }

    /// A root that is itself a symlink resolves outside the home, so it is
    /// refused whole and nothing it reaches is touched.
    func testCleanRefusesARootThatIsASymlink() async throws {
        let parent = home.appendingPathComponent(".npm")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("_cacache"), withDestinationURL: outside)

        let report = await cleaner.clean(.npm)
        let size = await cleaner.size(of: .npm)

        XCTAssertNil(report)
        XCTAssertEqual(size, 0)
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// A symlink anywhere on the way down to the root is refused the same.
    func testCleanRefusesARootReachedThroughASymlinkedParent() async throws {
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("_cacache"), withIntermediateDirectories: true)
        try write(outside.appendingPathComponent("_cacache/entry"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".npm"), withDestinationURL: outside)

        let report = await cleaner.clean(.npm)

        XCTAssertNil(report)
        XCTAssertEqual(try contents(outside.appendingPathComponent("_cacache")), ["entry"])
    }

    /// An entry this user does not own is left with everything under it, and
    /// counted, while the rest goes.
    func testCleanSkipsWhatAnotherUserOwns() async throws {
        let root = try root()
        let foreign = root.appendingPathComponent("foreign")
        try write(foreign.appendingPathComponent("inside"))
        try write(root.appendingPathComponent("mine"))
        var status = stat()
        XCTAssertEqual(lstat(foreign.path, &status), 0)
        let foreignInode = status.st_ino
        let cleaner = DiskCleaner(home: home.path) { $0.st_ino != foreignInode && $0.st_uid == getuid() }
        let mine = allocated(root.appendingPathComponent("mine"))

        let size = await cleaner.size(of: .npm)
        let report = await cleaner.clean(.npm)

        XCTAssertEqual(size, mine)
        XCTAssertEqual(report, CleanupReport(removed: 1, removedBytes: mine, skipped: 1))
        XCTAssertEqual(try contents(root), ["foreign"])
        XCTAssertEqual(try contents(foreign), ["inside"])
    }

    /// A directory left holding another user's entry is not counted a second
    /// time as a failure.
    func testCleanCountsANestedSkipOnce() async throws {
        let root = try root()
        let foreign = root.appendingPathComponent("outer/foreign")
        try write(foreign)
        try write(root.appendingPathComponent("outer/mine"))
        var status = stat()
        XCTAssertEqual(lstat(foreign.path, &status), 0)
        let foreignInode = status.st_ino
        let cleaner = DiskCleaner(home: home.path) { $0.st_ino != foreignInode && $0.st_uid == getuid() }

        let report = await cleaner.clean(.npm)

        XCTAssertEqual(report?.removed, 1)
        XCTAssertEqual(report?.skipped, 1)
        XCTAssertEqual(report?.failed, 0)
        XCTAssertEqual(try contents(root.appendingPathComponent("outer")), ["foreign"])
    }

    /// A root another user owns is refused whole.
    func testCleanRefusesARootAnotherUserOwns() async throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let cleaner = DiskCleaner(home: home.path) { _ in false }

        let report = await cleaner.clean(.npm)

        XCTAssertNil(report)
        XCTAssertEqual(try contents(root), ["entry"])
    }

    /// What the filesystem refuses is counted and the rest still goes; the
    /// directory holding what stayed is not counted a second time.
    func testCleanReportsAPartialFailure() async throws {
        let root = try root()
        let locked = root.appendingPathComponent("locked")
        try write(locked.appendingPathComponent("one"))
        try write(locked.appendingPathComponent("two"))
        try write(root.appendingPathComponent("free"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let report = await cleaner.clean(.npm)

        XCTAssertEqual(report?.removed, 1)
        XCTAssertEqual(report?.failed, 2)
        XCTAssertEqual(report?.isComplete, false)
        XCTAssertEqual(try contents(root), ["locked"])
        XCTAssertEqual(try contents(locked), ["one", "two"])
    }

    /// A walk cancelled before it starts removes nothing and says it stopped.
    func testCancelledCleanRemovesNothing() throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let cancellation = CleanupCancellation()
        cancellation.cancel()

        let report = cleaner.clean(.npm, cancellation: cancellation)
        let size = cleaner.size(of: .npm, cancellation: cancellation)

        XCTAssertEqual(report, CleanupReport(cancelled: true))
        XCTAssertNil(size)
        XCTAssertEqual(try contents(root), ["entry"])
    }

    // MARK: Model

    /// Rows are the caches that take room; a clean sizes its row again and
    /// keeps it, with what it removed, until the panel closes.
    @MainActor
    func testModelSizesThenCleansOneRow() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("archive-v0/wheel"))
        let model = DiskCleanupModel(cleaner: cleaner)

        model.measure()
        try await waitUntil { model.measured }
        XCTAssertEqual(model.rows, [.uv])
        let before = try XCTUnwrap(model.sizes[.uv])

        model.clean(.uv)
        XCTAssertEqual(model.cleaning, .uv)
        try await waitUntil { model.cleaning == nil }

        XCTAssertEqual(model.rows, [.uv])
        XCTAssertEqual(model.sizes[.uv], 0)
        XCTAssertEqual(model.outcomes[.uv]?.report?.removed, 2)
        XCTAssertEqual(model.outcomes[.uv]?.report?.removedBytes, before)
        XCTAssertEqual(try contents(root), [])
    }

    /// A root refused at the press keeps the size it was offered at, rather
    /// than reading as emptied.
    @MainActor
    func testModelKeepsTheSizeOfARootRefusedAtThePress() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("wheel"))
        let model = DiskCleanupModel(cleaner: cleaner)
        model.measure()
        try await waitUntil { model.measured }
        let before = try XCTUnwrap(model.sizes[.uv])
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        model.clean(.uv)
        try await waitUntil { model.cleaning == nil }

        XCTAssertEqual(model.sizes[.uv], before)
        XCTAssertEqual(model.outcomes[.uv], .init(report: nil))
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// Cancelling for the panel closing leaves no removal marked in flight.
    @MainActor
    func testModelCancelClearsTheRemovalInFlight() throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("wheel"))
        let model = DiskCleanupModel(cleaner: cleaner)
        model.measure()
        model.cancel()

        XCTAssertNil(model.cleaning)
        XCTAssertFalse(model.measured)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// What the confirmation says before anything is removed.
final class DiskCleanupCopyTests: XCTestCase {
    /// The path, the size and that it cannot be undone, in one sentence.
    func testConfirmationNamesThePathTheSizeAndThatItIsPermanent() {
        let body = DiskCleanupCopy.confirmBody(.derivedData, bytes: 9_180_000_000)
        XCTAssertEqual(
            body,
            "Permanently removes everything inside ~/Library/Developer/Xcode/DerivedData, "
                + "up to 9.2 GB. Xcode rebuilds it on the next build.")
    }

    /// A partial removal says what stayed and why, beside what went.
    func testOutcomeSaysWhatWasLeft() {
        let outcome = DiskCleanupModel.Outcome(
            report: CleanupReport(removed: 40, removedBytes: 2_000_000_000, skipped: 1, failed: 3))
        XCTAssertEqual(
            DiskCleanupCopy.outcome(outcome, target: .npm),
            "Freed up to 2.0 GB · 3 items could not be removed · 1 item left as another user's or "
                + "another volume's")
    }
}
