import XCTest

@testable import Sissy

/// Which of the places Claude Code keeps its credential is the one it is
/// using, which is what the limits probe and the account registry both read.
final class ClaudeCLISlotTests: XCTestCase {
    private static let unscoped = ClaudeCLISlot.Name.keychain("unscoped")
    private static let scoped = ClaudeCLISlot.Name.keychain("scoped")

    private func slot(
        _ held: [ClaudeCLISlot.Name: Data], failing: [ClaudeCLISlot.Name: Error] = [:]
    ) -> ClaudeCLISlot {
        ClaudeCLISlot(
            names: { [Self.unscoped, Self.scoped, .file] },
            read: { name in
                if let failure = failing[name] { throw failure }
                return held[name]
            })
    }

    private func credential(_ token: String) -> Data {
        Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":1789487107266}}"#.utf8)
    }

    private func token(_ lookup: ClaudeCredentialsLookup) -> String? {
        guard case .found(let found) = lookup else { return nil }
        return found.accessToken
    }

    func testNothingHeldAnywhereIsAbsent() {
        guard case .absent = ClaudeCodeCredentials.load(slot: slot([:])) else {
            return XCTFail("a CLI that keeps no credential is absent")
        }
    }

    func testTheTokenAndItsExpiryAreRead() {
        guard
            case .found(let found) = ClaudeCodeCredentials.load(
                slot: slot([.file: credential("sk-ant-oat01-x")]))
        else { return XCTFail("a well-formed credential is found") }
        XCTAssertEqual(found.accessToken, "sk-ant-oat01-x")
        XCTAssertEqual(
            found.expiresAt?.timeIntervalSince1970 ?? 0, 1_789_487_107.266, accuracy: 0.01)
    }

    /// The keychain is where the CLI keeps its credential on macOS, so a file
    /// left behind by an earlier fallback does not answer over it.
    func testTheKeychainLeadsOverTheFile() {
        let held = slot([Self.unscoped: credential("tok-b"), .file: credential("tok-a")])

        XCTAssertEqual(token(ClaudeCodeCredentials.load(slot: held)), "tok-b")
    }

    func testTheFileAnswersWhenNoKeychainItemHoldsOne() {
        XCTAssertEqual(
            token(ClaudeCodeCredentials.load(slot: slot([.file: credential("tok-a")]))), "tok-a")
    }

    /// The scoped name is a sibling of the unscoped one and answers only when
    /// the unscoped one holds nothing.
    func testTheScopedItemAnswersOnlyWhenTheUnscopedHoldsNothing() {
        let held = slot([Self.scoped: credential("tok-a"), .file: credential("tok-c")])

        XCTAssertEqual(token(ClaudeCodeCredentials.load(slot: held)), "tok-a")
    }

    /// A file that carries no account half is a file with no credential in
    /// it, and the lookup goes on past it rather than stopping there.
    func testAFileWithNoAccountHalfCountsAsAbsent() {
        let held = slot([.file: Data(#"{"mcpOAuth":{"server":"x"}}"#.utf8)])

        guard case .absent = ClaudeCodeCredentials.load(slot: held) else {
            return XCTFail("a file with no claudeAiOauth holds no credential")
        }
    }

    /// Bytes that are not a credential blob are not a place with nothing in
    /// it: the lookup stops there rather than answering from the file behind.
    func testAMalformedUnscopedItemStopsTheLookup() {
        let held = slot([Self.unscoped: Data("not json".utf8), .file: credential("tok-a")])

        guard case .unreadable(let status) = ClaudeCodeCredentials.load(slot: held) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertEqual(status, OSStatus(errSecDecode))
    }

    /// A malformed file with nothing in front of it is unreadable, not absent.
    func testAMalformedFileAloneIsUnreadable() {
        let held = slot([.file: Data(#"{"claudeAiOauth":"#.utf8)])

        guard case .unreadable = ClaudeCodeCredentials.load(slot: held) else {
            return XCTFail("expected unreadable")
        }
    }

    /// An account half that is not an object is a blob that did not decode,
    /// which is a different claim from a blob that carries no account.
    func testAnAccountHalfThatIsNotAnObjectIsUnreadable() {
        let held = slot([Self.unscoped: Data(#"{"claudeAiOauth":"x"}"#.utf8)])

        guard case .unreadable = ClaudeCodeCredentials.load(slot: held) else {
            return XCTFail("expected unreadable")
        }
    }

    /// A place that could not be read says nothing about which credential the
    /// CLI is using, so the lookup stops rather than answering from the next.
    func testAnUnreadableItemIsUnreadableRatherThanFallingThrough() {
        let held = slot(
            [.file: credential("tok-a")],
            failing: [Self.unscoped: ClaudeKeychainCLI.Failure.tool(36)])

        guard case .unreadable(let status) = ClaudeCodeCredentials.load(slot: held) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertEqual(status, 36)
    }
}
