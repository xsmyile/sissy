import XCTest

@testable import Sissy

/// A log root the user moved to another disk and left a symlink behind for.
/// `FileManager.enumerator(at:)` on a URL that is itself a symlink to a
/// directory yields nothing, so the tail has to resolve the root before it
/// walks or watches it.
final class UsageLogRootTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-log-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private static let tokensPerTurn = 1_000_000

    private func writeTurn(in directory: URL) throws {
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try ClaudeLogFixture.writeTurn(
            to: project.appendingPathComponent("s.jsonl"), requestId: "r1",
            model: "claude-sonnet-4-6", input: Self.tokensPerTurn)
    }

    func testATurnUnderASymlinkedRootIsCounted() async throws {
        let target = base.appendingPathComponent("external")
        try writeTurn(in: target)
        let link = base.appendingPathComponent("projects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: link, retainDays: 2, pollInterval: .seconds(60), persistenceURL: nil)

        await provider.start { _ in }
        let today = await provider.current()
        await provider.stop()

        XCTAssertEqual(today.totalTokens, Self.tokensPerTurn)
    }

    func testTheResolvedRootIsTheLinkTarget() throws {
        let target = base.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("projects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = LocalUsageProvider.resolvedRoot(link)

        XCTAssertEqual(resolved.path, LocalUsageProvider.resolvedRoot(target).path)
        XCTAssertNotEqual(resolved.path, link.path)
    }

    func testARootThatDoesNotExistYetIsKeptAsConfigured() {
        let missing = base.appendingPathComponent("not-yet")

        XCTAssertEqual(LocalUsageProvider.resolvedRoot(missing).path, missing.path)
    }
}
