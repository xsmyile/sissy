import XCTest

@testable import Sissy

/// What `~/.codex/auth.json` is allowed to change about the Codex row.
///
/// The file is read at launch and again whenever the user asks, and between
/// those two reads the account behind it can be a different one. Everything
/// on the row is metered against that account — the plan, the windows — so
/// what a re-read may keep and what it must drop is the whole question.
final class CodexIdentityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-codex-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A plan the file names used to be taken only while none was held, so a
    /// second account's row kept the first's badge. The account is replaced
    /// either way, which is what made the pair contradict itself.
    func testADifferentAccountBringsItsOwnPlan() throws {
        let adapter = makeAdapter()
        try writeAuth(plan: "plus", email: "first@example.com")
        _ = adapter.prepareToStart()

        try writeAuth(plan: "pro", email: "second@example.com")
        _ = adapter.refreshOutOfBandState()

        XCTAssertEqual(adapter.descriptor.signals.currentSignals().plan, "pro")
        XCTAssertEqual(
            adapter.descriptor.signals.currentSignals().account?.email, "second@example.com")
    }

    /// Signing out, or switching the CLI to an API key, leaves no
    /// subscription to report. The read used to fail outright on that file and
    /// leave the previous account on screen.
    func testSwitchingToAnAPIKeyClearsTheAccountAndThePlan() throws {
        let adapter = makeAdapter()
        try writeAuth(plan: "plus", email: "first@example.com")
        _ = adapter.prepareToStart()

        try Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"fixture"}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        _ = adapter.refreshOutOfBandState()

        XCTAssertNil(adapter.descriptor.signals.currentSignals().plan)
        XCTAssertNil(adapter.descriptor.signals.currentSignals().account)
    }

    /// A file mid-write is not a logout. Codex rewrites it on every token
    /// refresh, and blanking the row on each one would be a row that flickers
    /// for no reason the user could name.
    func testAFileThatWillNotParseLeavesTheRowAlone() throws {
        let adapter = makeAdapter()
        try writeAuth(plan: "plus", email: "first@example.com")
        _ = adapter.prepareToStart()

        try Data("{ not json".utf8).write(to: root.appendingPathComponent("auth.json"))
        _ = adapter.refreshOutOfBandState()

        XCTAssertEqual(adapter.descriptor.signals.currentSignals().plan, "plus")
        XCTAssertEqual(
            adapter.descriptor.signals.currentSignals().account?.email, "first@example.com")
    }

    /// A token naming none of the claims the digest is built from cannot say
    /// whose it is, and "I do not know" is not "somebody else". Treating it as
    /// a different account blanked a plan and a set of gauges that were
    /// correct — on a file Codex rewrites on every token refresh.
    func testATokenThatNamesNobodyIsNotTreatedAsADifferentAccount() throws {
        let adapter = makeAdapter()
        try writeAuth(plan: "plus", email: "first@example.com")
        _ = adapter.prepareToStart()

        try writeAnonymousAuth()
        _ = adapter.prepareToStart()

        XCTAssertEqual(adapter.descriptor.signals.currentSignals().plan, "plus")
    }

    private func makeAdapter() -> CodexAdapter {
        CodexAdapter(
            codexDir: root.appendingPathComponent("sessions"),
            pricingOverride: nil,
            ledger: ProjectLedger(url: root.appendingPathComponent("projects.json")))
    }

    /// Signed in, but naming no `sub`, no account id and no address — the
    /// shape the digest cannot be built from.
    private func writeAnonymousAuth() throws {
        try writeIDToken(claims: ["https://api.openai.com/auth": [:]])
    }

    private func writeAuth(plan: String, email: String) throws {
        let claims: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
        ]
        try writeIDToken(claims: claims)
    }

    /// The claims Codex's own id_token carries, in the shape it carries them.
    /// The signature is never checked — every field taken is a display string
    /// read off the user's own disk — so an unsigned third segment is faithful
    /// enough.
    private func writeIDToken(claims: [String: Any]) throws {
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
