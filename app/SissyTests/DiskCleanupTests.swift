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

    private func inode(_ url: URL) throws -> ino_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return status.st_ino
    }

    private func contents(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private var cleaner: DiskCleaner { makeCleaner() }

    /// A cleaner over the temporary home that reads no process table, with
    /// the ownership, volume and tool seams a test sets.
    private func makeCleaner(
        owns: @escaping @Sendable (stat) -> Bool = { $0.st_uid == getuid() },
        device: @escaping @Sendable (stat) -> dev_t = { $0.st_dev },
        running: Set<CleanupTool> = [],
        directoryOpened: (@Sendable (String) -> Void)? = nil
    ) -> DiskCleaner {
        DiskCleaner(
            home: home.path, owns: owns, device: device, runningTools: { running },
            directoryOpened: directoryOpened)
    }

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

        let report = try await cleaner.clean(.npm).get()

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

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.removed, 2)
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
        let report = try await cleaner.clean(.npm).get()

        XCTAssertLessThan(size ?? .max, allocated(outside.appendingPathComponent("keep.bin")))
        XCTAssertEqual(report.removed, 4)
        XCTAssertEqual(report.isComplete, true)
        XCTAssertEqual(try contents(root), [])
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// A file still linked outside the root is removed from it and frees
    /// nothing, and the other link keeps its contents.
    func testCleanCountsNoBytesForAFileLinkedOutside() async throws {
        let root = try root()
        try FileManager.default.linkItem(
            at: outside.appendingPathComponent("keep.bin"), to: root.appendingPathComponent("shared"))

        let report = try await cleaner.clean(.npm).get()

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

        let result = await cleaner.clean(.npm)

        XCTAssertEqual(result, .failure(.unsafeRoot))
        XCTAssertEqual(try contents(wrongCase), ["entry"])
    }

    /// A root that is itself a symlink resolves outside the home, so it is
    /// refused whole and nothing it reaches is touched.
    func testCleanRefusesARootThatIsASymlink() async throws {
        let parent = home.appendingPathComponent(".npm")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("_cacache"), withDestinationURL: outside)

        let result = await cleaner.clean(.npm)
        let size = await cleaner.size(of: .npm)

        XCTAssertEqual(result, .failure(.unsafeRoot))
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

        let result = await cleaner.clean(.npm)

        XCTAssertEqual(result, .failure(.unsafeRoot))
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
        let cleaner = makeCleaner(owns: { $0.st_ino != foreignInode && $0.st_uid == getuid() })
        let mine = allocated(root.appendingPathComponent("mine"))

        let size = await cleaner.size(of: .npm)
        let report = try await cleaner.clean(.npm).get()

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
        let cleaner = makeCleaner(owns: { $0.st_ino != foreignInode && $0.st_uid == getuid() })

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try contents(root.appendingPathComponent("outer")), ["foreign"])
    }

    /// A root another user owns is refused whole.
    func testCleanRefusesARootAnotherUserOwns() async throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let cleaner = makeCleaner(owns: { _ in false })

        let result = await cleaner.clean(.npm)

        XCTAssertEqual(result, .failure(.unsafeRoot))
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

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.isComplete, false)
        XCTAssertEqual(try contents(root), ["locked"])
        XCTAssertEqual(try contents(locked), ["one", "two"])
    }

    /// A directory renamed out of the root after it was opened is left where
    /// it went, with everything in it, and the rest of the root still goes.
    func testCleanLeavesADirectoryMovedOutOfTheRoot() async throws {
        let root = try root()
        try write(root.appendingPathComponent("moving/inner.bin"))
        try write(root.appendingPathComponent("stays/other.bin"))
        let moved = outside.appendingPathComponent("moved")
        let cleaner = makeCleaner(
            directoryOpened: { path in
                guard path.hasSuffix("/moving") else { return }
                try? FileManager.default.moveItem(atPath: path, toPath: moved.path)
            })

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(try contents(moved), ["inner.bin"])
        XCTAssertEqual(try contents(root), [])
    }

    /// A root on another device than the home, as a volume mounted at the root
    /// or above it would be, is refused whole.
    func testCleanRefusesARootOnAnotherVolume() async throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let rootInode = try inode(root)
        let cleaner = makeCleaner(
            device: { $0.st_ino == rootInode ? $0.st_dev &+ 1 : $0.st_dev })

        let result = await cleaner.clean(.npm)
        let size = await cleaner.size(of: .npm)

        XCTAssertEqual(result, .failure(.unsafeRoot))
        XCTAssertEqual(size, 0)
        XCTAssertEqual(try contents(root), ["entry"])
    }

    /// An entry on another device inside a root is skipped with what is under
    /// it, and counted.
    func testCleanSkipsAnEntryOnAnotherVolume() async throws {
        let root = try root()
        let mounted = root.appendingPathComponent("mounted")
        try write(mounted.appendingPathComponent("inside"))
        try write(root.appendingPathComponent("local"))
        let mountedInode = try inode(mounted)
        let cleaner = makeCleaner(
            device: { $0.st_ino == mountedInode ? $0.st_dev &+ 1 : $0.st_dev })

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(try contents(root), ["mounted"])
        XCTAssertEqual(try contents(mounted), ["inside"])
    }

    /// A tree deeper than `maxDepth` is neither sized nor removed past it, and
    /// the one directory the walk would not enter is counted once.
    func testWalkStopsAtMaxDepth() async throws {
        let root = try root()
        let deepest = (0...DiskCleaner.maxDepth).reduce(root) { $0.appendingPathComponent("d\($1)") }
        let file = deepest.appendingPathComponent("bottom.bin")
        try write(file)
        let fileBlocks = allocated(file)

        let size = await cleaner.size(of: .npm)
        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(size, 0)
        XCTAssertGreaterThan(fileBlocks, 0)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A directory swapped for a symlink between being examined and being
    /// opened is not entered, and what the link points at is untouched.
    func testCleanDoesNotEnterADirectorySwappedForASymlink() async throws {
        let root = try root()
        let swapped = root.appendingPathComponent("swapped")
        try write(swapped.appendingPathComponent("inner"))
        let swappedInode = try inode(swapped)
        let outside = outside!
        let cleaner = makeCleaner(owns: { status in
            if status.st_ino == swappedInode {
                try? FileManager.default.removeItem(at: swapped)
                try? FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: outside)
            }
            return status.st_uid == getuid()
        })

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// A directory swapped for another directory in that moment is not
    /// entered either: the one opened is not the inode that was examined.
    func testCleanDoesNotEnterADirectorySwappedForAnother() async throws {
        let root = try root()
        let swapped = root.appendingPathComponent("swapped")
        try write(swapped.appendingPathComponent("inner"))
        let other = outside.appendingPathComponent("other")
        try write(other.appendingPathComponent("theirs"))
        let swappedInode = try inode(swapped)
        let aside = outside.appendingPathComponent("aside")
        let cleaner = makeCleaner(owns: { status in
            if status.st_ino == swappedInode {
                try? FileManager.default.moveItem(at: swapped, to: aside)
                try? FileManager.default.moveItem(at: other, to: swapped)
            }
            return status.st_uid == getuid()
        })

        let report = try await cleaner.clean(.npm).get()

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(try contents(swapped), ["theirs"])
    }

    // MARK: The tool at work

    /// A cache whose tool is running is refused, and the press says which.
    func testCleanRefusesWhileTheToolRuns() async throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let cleaner = makeCleaner(running: [.npm])

        let result = await cleaner.clean(.npm)
        let atWork = await cleaner.toolAtWork(on: .npm)

        XCTAssertEqual(result, .failure(.toolRunning(.npm)))
        XCTAssertEqual(atWork, .npm)
        XCTAssertEqual(try contents(root), ["entry"])
    }

    /// Another cache's tool running does not hold this one.
    func testCleanIgnoresAnotherCachesTool() async throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))

        let result = await makeCleaner(running: [.xcode]).clean(.npm)

        XCTAssertEqual(try result.get().removed, 1)
    }

    /// uv's lock held by a running uv refuses the cleanup, whatever the
    /// process table says.
    func testUvCleanRefusesWhileUvHoldsItsLock() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("archive-v0/wheel"))
        try write(root.appendingPathComponent(".lock"), bytes: 0)
        let held = open(root.appendingPathComponent(".lock").path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_SH | LOCK_NB), 0)
        defer { close(held) }

        let result = await cleaner.clean(.uv)

        XCTAssertEqual(result, .failure(.toolRunning(.uv)))
        XCTAssertEqual(try contents(root), [".lock", "archive-v0"])
    }

    /// With the lock free the cleanup holds it and keeps the file, so a uv
    /// started meanwhile waits on the same lock rather than a new one.
    func testUvCleanKeepsItsLockFile() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("archive-v0/wheel"))
        try write(root.appendingPathComponent(".lock"), bytes: 0)

        let report = try await makeCleaner(running: [.uv]).clean(.uv).get()

        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(try contents(root), [".lock"])
    }

    /// A uv cache with no lock file falls back to the process table.
    func testUvCleanWithoutALockReadsTheProcessTable() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("archive-v0/wheel"))

        let result = await makeCleaner(running: [.uv]).clean(.uv)

        XCTAssertEqual(result, .failure(.toolRunning(.uv)))
    }

    /// Which processes are a cache's tool at work.
    func testToolScanClassifiesProcesses() {
        func tool(_ path: String, title: String? = nil, children: Bool = false) -> CleanupTool? {
            CleanupToolScan.tool(
                of: .init(pid: 1, parent: 0, executablePath: path, startedAt: .distantPast),
                hasChildren: children, title: { _ in title })
        }
        let xcode = "/Applications/Xcode.app/Contents"
        let node = "/opt/homebrew/bin/node"
        XCTAssertEqual(tool(xcode + "/MacOS/Xcode"), .xcode)
        XCTAssertEqual(tool(xcode + "/Developer/usr/bin/xcodebuild"), .xcode)
        XCTAssertEqual(
            tool(
                xcode + "/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/"
                    + "SWBBuildService.bundle/Contents/MacOS/SWBBuildService"), .xcode)
        XCTAssertEqual(tool("/opt/homebrew/bin/uv"), .uv)
        XCTAssertEqual(tool(node, title: "npm install typescript@5"), .npm)
        XCTAssertEqual(tool(node, title: "npm exec chrome-devtools-mcp@1.9.0"), .npm)
        XCTAssertNil(tool(node, title: "npm exec chrome-devtools-mcp@1.9.0", children: true))
        XCTAssertNil(tool(node, title: "node server.js"))
        XCTAssertNil(tool("/usr/bin/python3"))
    }

    /// A walk cancelled before it starts removes nothing and says it stopped.
    func testCancelledCleanRemovesNothing() throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let cancellation = CleanupCancellation()
        cancellation.cancel()

        let report = try cleaner.clean(.npm, cancellation: cancellation).get()
        let size = cleaner.size(of: .npm, cancellation: cancellation)

        XCTAssertEqual(report, CleanupReport(cancelled: true))
        XCTAssertNil(size)
        XCTAssertEqual(try contents(root), ["entry"])
    }

    // MARK: Model

    /// A press sizes the cache again, so the question names what will go now
    /// rather than what the cache took when the panel opened.
    @MainActor
    func testConfirmationResizesTheCache() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("archive-v0/wheel"))
        let model = DiskCleanupModel(host: DiskCleanupHost(cleaner: cleaner))
        model.measure()
        try await waitUntil { model.measured }
        let measured = model.size(of: .uv)
        try write(root.appendingPathComponent("archive-v0/refilled"), bytes: 200_000)

        model.propose(.uv)
        try await waitUntil { model.confirmation != nil }

        XCTAssertEqual(model.confirmation?.target, .uv)
        XCTAssertGreaterThan(model.confirmation?.bytes ?? 0, measured)
        XCTAssertEqual(try contents(root.appendingPathComponent("archive-v0")), ["refilled", "wheel"])
    }

    /// A press on a cache whose tool is at work asks nothing and says so.
    @MainActor
    func testPressOnACacheInUseSaysWhichTool() async throws {
        let root = try root()
        try write(root.appendingPathComponent("entry"))
        let model = DiskCleanupModel(host: DiskCleanupHost(cleaner: makeCleaner(running: [.npm])))
        model.measure()
        try await waitUntil { model.measured }

        model.propose(.npm)
        try await waitUntil { model.preparing == nil }

        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.atWork[.npm], .npm)
        XCTAssertEqual(try contents(root), ["entry"])
    }

    /// A confirmed removal goes on when the panel closes, and the panel opened
    /// next shows what it did; that panel closing drops the outcome.
    @MainActor
    func testRemovalSurvivesThePanelClosing() async throws {
        let root = try root(.uv)
        let file = root.appendingPathComponent("archive-v0/wheel")
        try write(file)
        let fileBlocks = allocated(file)
        let host = DiskCleanupHost(cleaner: cleaner)
        let first = DiskCleanupModel(host: host)
        first.measure()
        try await waitUntil { first.measured }
        first.propose(.uv)
        try await waitUntil { first.confirmation != nil }

        first.confirm()
        first.cancel()
        XCTAssertEqual(host.removals[.uv], .running)
        try await waitUntil { host.removals[.uv] != .running }

        guard case .finished(let outcome) = host.removals[.uv] else { return XCTFail("no outcome") }
        let report = try outcome.result.get()
        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(report.removedBytes, fileBlocks)
        XCTAssertGreaterThan(fileBlocks, 0)
        XCTAssertEqual(outcome.remaining, 0)
        XCTAssertEqual(try contents(root), [])
        let next = DiskCleanupModel(host: host)
        XCTAssertEqual(next.rows, [.uv])
        XCTAssertEqual(next.size(of: .uv), 0)
        next.cancel()
        XCTAssertNil(host.removals[.uv])
    }

    /// A root refused at the press keeps the size it was offered at, rather
    /// than reading as emptied.
    @MainActor
    func testRemovalOfARefusedRootKeepsItsSize() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("wheel"))
        let host = DiskCleanupHost(cleaner: cleaner)
        let model = DiskCleanupModel(host: host)
        model.measure()
        try await waitUntil { model.measured }
        model.propose(.uv)
        try await waitUntil { model.confirmation != nil }
        let offered = model.size(of: .uv)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        model.confirm()
        try await waitUntil { host.removals[.uv] != .running }

        XCTAssertEqual(host.removals[.uv], .finished(.init(result: .failure(.unsafeRoot), remaining: nil)))
        XCTAssertEqual(model.size(of: .uv), offered)
        XCTAssertEqual(try contents(outside), ["keep.bin"])
    }

    /// Closing the panel cancels its sizing: nothing more is measured.
    @MainActor
    func testClosingThePanelCancelsTheSizing() async throws {
        let root = try root(.uv)
        try write(root.appendingPathComponent("wheel"))
        let model = DiskCleanupModel(host: DiskCleanupHost(cleaner: cleaner))

        model.measure()
        model.cancel()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(model.measured)
        XCTAssertTrue(model.sizes.isEmpty)
    }

    /// A sizing asked for while a removal of the same root runs waits for it,
    /// which is what a panel opened again while the last one's walk unwinds
    /// meets.
    @MainActor
    func testSizingWaitsForARemovalOfTheSameRoot() async throws {
        let root = try root(.uv)
        for index in 0..<50 { try write(root.appendingPathComponent("archive-v0/wheel-\(index)")) }
        let host = DiskCleanupHost(cleaner: cleaner)

        host.remove(.uv)
        let size = await host.size(of: .uv)

        XCTAssertEqual(size, 0)
        try await waitUntil { host.removals[.uv] != .running }
        XCTAssertEqual(try contents(root), [])
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
        let outcome = DiskCleanupHost.Outcome(
            result: .success(
                CleanupReport(removed: 40, removedBytes: 2_000_000_000, skipped: 1, failed: 3)),
            remaining: 0)
        XCTAssertEqual(
            DiskCleanupCopy.outcome(outcome, target: .npm),
            "Freed up to 2.0 GB · 3 items could not be removed · 1 item left as another user's or "
                + "another volume's")
    }
}
