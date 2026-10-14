import XCTest

@testable import Sissy

/// When a tail with no turn in its window publishes its first reading.
///
/// A provider that has never emitted has no slice, so no row: a signed-in CLI
/// left unused across a relaunch lost its gauges and its plan until the next
/// turn, while one that has read nothing at all must still leave the panel on
/// the sentence that says there are no session logs.
final class ProviderFirstReadingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-first-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try writeIdleRollout()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions") }

    func testASignedInCLIWithNoTurnInTheWindowStillPublishes() async throws {
        try writeAuth(plan: "plus", email: "someone@example.com")

        let emitted = await readings()

        XCTAssertEqual(emitted, [0], "a signed-in provider with nothing spent left no slice")
    }

    func testACLINobodyIsSignedIntoAndNoTurnInTheWindowStaysSilent() async throws {
        let emitted = await readings()

        XCTAssertEqual(emitted, [], "a provider that read nothing published a reading")
    }

    /// The token totals of every reading the tail published through its cold
    /// scan.
    private func readings() async -> [Int] {
        let provider = LocalUsageProvider.codex(
            codexDir: sessionsDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.forProvider(ProviderID.codex, in: root),
            ledger: ProjectLedger(url: ProjectLedger.defaultURL(in: root))
        )
        let emitted = LockedValue<[Int]>([])
        await provider.start { today in emitted.update { $0.append(today.totalTokens) } }
        await provider.stop()
        return emitted.load()
    }

    /// A rollout last written well before the retain window, so the tree is
    /// not empty and the window holds no turn.
    private func writeIdleRollout() throws {
        let url = sessionsDir.appendingPathComponent("idle.jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"idle"}}"# + "\n").utf8).write(to: url)
        let old = Date().addingTimeInterval(-5 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    /// An `auth.json` whose id_token names an address and a plan, the shape
    /// `CodexIdentityTests` writes; the signature is never checked.
    private func writeAuth(plan: String, email: String) throws {
        let claims: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let auth = ["tokens": ["id_token": "header.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: root.appendingPathComponent("auth.json"))
    }
}
