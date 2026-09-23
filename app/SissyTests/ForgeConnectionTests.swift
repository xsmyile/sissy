import XCTest

@testable import Sissy

/// What a forge connection is made of before anything is filed: the address
/// parsed out of the sheet's fields, the index it is recorded in, and the probe
/// a token has to pass before either is written.
///
/// Pure or on a temporary directory: no keychain and no network, the effects
/// of a connect standing in as closures that record what they were asked.
final class ForgeConnectionTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-connection-tests-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var index: ForgeConnectionIndex {
        ForgeConnectionIndex(url: ForgeConnectionIndex.defaultURL(in: directory))
    }

    private func parse(_ host: String, path: String = "", kind: ForgeKind = .gitLab)
        -> Result<ForgeConnection, ForgeAddressProblem>
    {
        ForgeConnection.parse(kind: kind, host: host, path: path)
    }

    // MARK: The address

    /// What a browser hands over when the host is copied out of its address
    /// bar: a scheme, a trailing slash, the path of the page, and capitals.
    func testHostIsTakenOutOfWhateverWasPasted() throws {
        XCTAssertEqual(try parse(" GitLab.Example.com ").get().host, "gitlab.example.com")
        XCTAssertEqual(try parse("https://gitlab.example.com/").get().host, "gitlab.example.com")
        XCTAssertEqual(
            try parse("https://gitlab.example.com/dashboard").get().host, "gitlab.example.com")
    }

    /// `http://` used to be taken off and the connection asked over https
    /// anyway, so a plain-http instance was probed on the wrong scheme and
    /// reported as unreachable. It is refused with its own reason instead: a
    /// token, often a write-scoped one, is not sent in the clear.
    func testPlainHttpIsRefused() {
        XCTAssertEqual(parse("http://gitlab.lan:8080"), .failure(.insecureScheme))
        XCTAssertEqual(parse("HTTP://gitlab.example.com/"), .failure(.insecureScheme))
    }

    func testAPortIsKeptAndReachesTheRoot() throws {
        let connection = try parse("https://gitlab.corp.example:8443/").get()
        XCTAssertEqual(connection.host, "gitlab.corp.example")
        XCTAssertEqual(connection.port, 8443)
        XCTAssertEqual(connection.root?.absoluteString, "https://gitlab.corp.example:8443")
    }

    /// `443` is what `https` answers on anyway, and keeping it would make one
    /// instance two connections with two tokens.
    func testTheSchemesOwnPortIsTheSameConnectionAsNone() throws {
        XCTAssertEqual(
            try parse("gitlab.example.com:443").get(), try parse("gitlab.example.com").get())
    }

    func testABasePathIsNormalisedAndReachesTheEndpoints() throws {
        let connection = try parse("corp.example", path: " gitlab/ ").get()
        XCTAssertEqual(connection.basePath, "/gitlab")
        XCTAssertEqual(connection.root?.absoluteString, "https://corp.example/gitlab")
        let events = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(connection, period: .all, now: Date()))
        XCTAssertTrue(
            events.absoluteString.hasPrefix("https://corp.example/gitlab/api/v4/events"),
            events.absoluteString)
    }

    func testAUserPrefixIsRefused() {
        XCTAssertEqual(parse("davide@gitlab.example.com"), .failure(.credentials))
        XCTAssertEqual(parse("https://davide:secret@gitlab.example.com/"), .failure(.credentials))
    }

    func testAQueryIsRefused() {
        XCTAssertEqual(parse("gitlab.example.com?private_token=x"), .failure(.query))
        XCTAssertEqual(parse("gitlab.example.com", path: "gitlab?x=1"), .failure(.query))
    }

    func testAFragmentIsRefused() {
        XCTAssertEqual(parse("gitlab.example.com/#top"), .failure(.fragment))
    }

    func testASchemeMistakeIsRefused() {
        XCTAssertEqual(parse("ftp://gitlab.example.com"), .failure(.scheme))
        XCTAssertEqual(parse("htps://gitlab.example.com"), .failure(.scheme))
        XCTAssertEqual(parse("https//gitlab.example.com"), .failure(.scheme))
        XCTAssertEqual(parse("https:/gitlab.example.com"), .failure(.scheme))
        XCTAssertEqual(parse("https://https://gitlab.example.com"), .failure(.scheme))
    }

    func testAPortOutOfRangeIsRefused() {
        XCTAssertEqual(parse("gitlab.example.com:0"), .failure(.port))
        XCTAssertEqual(parse("gitlab.example.com:65536"), .failure(.port))
        XCTAssertEqual(parse("gitlab.example.com:https"), .failure(.port))
        XCTAssertEqual(parse("gitlab.example.com:"), .failure(.port))
    }

    func testAHostNoNameCanCarryIsRefused() {
        XCTAssertEqual(parse("gitlab example.com"), .failure(.host))
        XCTAssertEqual(parse("-gitlab.example.com"), .failure(.host))
        XCTAssertEqual(parse("gitlab..example.com"), .failure(.host))
    }

    func testAPathThatClimbsOutIsRefused() {
        XCTAssertEqual(parse("corp.example", path: "../admin"), .failure(.path))
    }

    func testNothingTypedIsEmpty() {
        XCTAssertEqual(parse("   "), .failure(.empty))
        XCTAssertEqual(parse("https://"), .failure(.empty))
    }

    /// A connection with neither a port nor a path keeps the id it always had,
    /// so the tokens filed under it before either existed are still found.
    func testAnIdWithoutAPortOrPathIsTheOneItAlwaysWas() throws {
        XCTAssertEqual(try parse("gitlab.example.com").get().id, "gitlab:gitlab.example.com")
        XCTAssertEqual(
            try parse("gitlab.example.com:8443", path: "/gitlab").get().id,
            "gitlab:gitlab.example.com:8443/gitlab")
    }

    /// An index written before the port and the path existed decodes into
    /// connections with neither.
    func testAnIndexFromBeforeThePortDecodes() throws {
        let old = #"{"connections":[{"host":"gitlab.example.com","kind":"gitlab"}]}"#
        try Data(old.utf8).write(to: index.url)
        XCTAssertEqual(try index.load(), [ForgeConnection(kind: .gitLab, host: "gitlab.example.com")])
    }

    func testAGitHubEnterpriseOnAPortAsksItsOwnEndpoint() throws {
        let enterprise = try parse("github.corp.example:8443", kind: .gitHub).get()
        XCTAssertEqual(
            GitHubActivityFeed.endpoint(enterprise)?.absoluteString,
            "https://github.corp.example:8443/api/graphql")
    }

    // MARK: The index

    func testAnAbsentIndexIsEmpty() throws {
        XCTAssertEqual(try index.load(), [])
    }

    func testAnUnreadableIndexThrowsRatherThanReadingEmpty() throws {
        try Data("{\"connections\":[".utf8).write(to: index.url)
        XCTAssertThrowsError(try index.load())
    }

    /// The defect this whole half is for: the next connection used to write
    /// over a file that would not read, and the tokens it named were orphaned.
    func testAnUnreadableIndexIsNeverOverwritten() throws {
        let garbled = Data("{\"connections\":[".utf8)
        try garbled.write(to: index.url)
        XCTAssertThrowsError(try index.remember(ForgeConnection.gitHub()))
        XCTAssertThrowsError(try index.forget(id: ForgeConnection.gitHub().id))
        XCTAssertEqual(try Data(contentsOf: index.url), garbled)
    }

    func testAnEmptyIndexFileIsUnreadable() throws {
        try Data().write(to: index.url)
        XCTAssertThrowsError(try index.load())
    }

    func testAnUnreadableIndexIsMovedAsideWithItsBytes() throws {
        let garbled = Data("{\"connections\":[".utf8)
        try garbled.write(to: index.url)
        XCTAssertEqual(try index.loadSettingAside(), [])
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(ForgeConnectionIndex.setAsidePrefix) }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(aside.first))),
            garbled)
        XCTAssertTrue(index.hasSetAside())
    }

    /// Once the unreadable file is aside, a new connection starts a fresh one
    /// rather than being refused for ever.
    func testAConnectionAfterTheSetAsideStartsAFreshIndex() throws {
        try Data("{\"connections\":[".utf8).write(to: index.url)
        _ = try index.loadSettingAside()
        try index.remember(ForgeConnection.gitHub())
        XCTAssertEqual(try index.load(), [ForgeConnection.gitHub()])
    }

    /// A file that would not be read at all, rather than one that read and
    /// did not decode, may be a perfectly good index behind a passing lock or
    /// a permission. Moving it aside turned every connection it named into an
    /// orphaned token Settings offered to remove, so it is left where it is.
    func testAnIndexThatCannotBeReadIsLeftInPlace() throws {
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try index.loadSettingAside())
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.url.path))
        XCTAssertFalse(index.hasSetAside())
    }

    func testAReadableIndexIsNotSetAside() throws {
        try index.remember(ForgeConnection.gitHub())
        XCTAssertEqual(try index.loadSettingAside(), [ForgeConnection.gitHub()])
        XCTAssertFalse(index.hasSetAside())
    }

    // MARK: Reconciliation

    func testATokenNoConnectionNamesIsAnOrphan() {
        let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")
        XCTAssertEqual(
            ForgeConnectionIndex.orphans(
                stored: [gitLab.id, "gitlab:old.example.com", ForgeConnection.gitHub().id],
                connected: [ForgeConnection.gitHub(), gitLab]),
            ["gitlab:old.example.com"])
    }

    /// A keychain standing in for the forge token items: a list of ids and a
    /// delete that records what it was asked to remove.
    private final class TokenShelf: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String]
        private var removed: [String] = []

        init(_ ids: [String]) { self.ids = ids }

        var stored: [String] { lock.withLock { ids } }
        var deleted: [String] { lock.withLock { removed } }

        func delete(_ id: String) {
            lock.withLock {
                removed.append(id)
                ids.removeAll { $0 == id }
            }
        }
    }

    private func reconciler(_ shelf: TokenShelf) -> ForgeTokenReconciler {
        ForgeTokenReconciler(
            index: index, storedTokens: { shelf.stored }, deleteToken: { shelf.delete($0) })
    }

    private static let orphanID = "gitlab:old.example.com"

    func testTheStateListsTheConnectionsAndTheTokensNoneOfThemName() throws {
        try index.remember(ForgeConnection.gitHub())
        let shelf = TokenShelf([ForgeConnection.gitHub().id, Self.orphanID])
        let state = reconciler(shelf).state()
        XCTAssertEqual(state.connections, [ForgeConnection.gitHub()])
        XCTAssertEqual(state.orphanedTokens, [Self.orphanID])
        XCTAssertFalse(state.unreadable)
    }

    /// An index that cannot be read names nothing, so no token can be called
    /// an orphan against it; the state says it is unreadable instead, which is
    /// what Settings warns with.
    func testAnUnreadableIndexListsNoOrphansAndSaysSo() throws {
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: false)
        let state = reconciler(TokenShelf([Self.orphanID])).state()
        XCTAssertTrue(state.unreadable)
        XCTAssertEqual(state.orphanedTokens, [])
    }

    func testAnOrphanedTokenIsRemoved() throws {
        let shelf = TokenShelf([Self.orphanID])
        XCTAssertTrue(try reconciler(shelf).removeOrphan(id: Self.orphanID))
        XCTAssertEqual(shelf.deleted, [Self.orphanID])
    }

    /// The list was drawn before a connect named this id: removing its token
    /// now is a disconnect, and the row would be left with nothing to read.
    func testATokenTheIndexHasComeToNameIsLeftAlone() throws {
        let shelf = TokenShelf([Self.gitLab.id])
        try index.remember(Self.gitLab)
        XCTAssertFalse(try reconciler(shelf).removeOrphan(id: Self.gitLab.id))
        XCTAssertEqual(shelf.deleted, [])
    }

    func testNothingIsRemovedWhileTheIndexCannotBeRead() throws {
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: false)
        let shelf = TokenShelf([Self.orphanID])
        XCTAssertFalse(try reconciler(shelf).removeOrphan(id: Self.orphanID))
        XCTAssertEqual(shelf.deleted, [])
    }

    // MARK: The probe

    private final class Effects: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []

        func record(_ entry: String) {
            lock.withLock { log.append(entry) }
        }

        var entries: [String] { lock.withLock { log } }
    }

    private struct Refusal: Error {}

    private func connector(
        _ effects: Effects, probe: Result<String, ForgeReadFailure> = .success("davide"),
        recorded: Result<[ForgeConnection], Refusal> = .success([]), rememberFails: Bool = false
    ) -> ForgeConnector {
        ForgeConnector(
            recorded: { try recorded.get() },
            probe: { connection, _ in
                effects.record("probe \(connection.id)")
                return try probe.get()
            },
            saveToken: { _, id in effects.record("save \(id)") },
            deleteToken: { id in effects.record("delete \(id)") },
            remember: { connection in
                effects.record("remember \(connection.id)")
                if rememberFails { throw Refusal() }
            })
    }

    private static let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")

    func testARefusedTokenIsNotSaved() async {
        let effects = Effects()
        let outcome = await connector(effects, probe: .failure(.unauthorized))
            .connect(Self.gitLab, token: "glpat-test")
        XCTAssertEqual(outcome, .refused(.unauthorized))
        XCTAssertEqual(effects.entries, ["probe \(Self.gitLab.id)"])
    }

    func testAHostThatCannotBeReachedSavesNothing() async {
        let effects = Effects()
        let outcome = await connector(effects, probe: .failure(.unreachable))
            .connect(Self.gitLab, token: "glpat-test")
        XCTAssertEqual(outcome, .refused(.unreachable))
        XCTAssertEqual(effects.entries, ["probe \(Self.gitLab.id)"])
    }

    func testAnAcceptedTokenIsSavedThenRecorded() async {
        let effects = Effects()
        let outcome = await connector(effects)
            .connect(Self.gitLab, token: "glpat-test")
        XCTAssertEqual(outcome, .connected(login: "davide"))
        XCTAssertEqual(
            effects.entries,
            ["probe \(Self.gitLab.id)", "save \(Self.gitLab.id)", "remember \(Self.gitLab.id)"])
    }

    /// A new token whose connection could not be recorded is taken back out,
    /// rather than left in the keychain for nothing to name.
    func testANewTokenWhoseIndexWriteFailedIsTakenBack() async {
        let effects = Effects()
        let outcome = await connector(effects, rememberFails: true)
            .connect(Self.gitLab, token: "glpat-test")
        XCTAssertEqual(outcome, .notFiled)
        XCTAssertEqual(effects.entries.last, "delete \(Self.gitLab.id)")
    }

    /// A replacement's token is kept on the same failure: deleting it would
    /// leave the row the index still names with no token at all.
    func testAReplacementTokenSurvivesAFailedIndexWrite() async {
        let effects = Effects()
        let outcome = await connector(effects, recorded: .success([Self.gitLab]), rememberFails: true)
            .connect(Self.gitLab, token: "glpat-test")
        XCTAssertEqual(outcome, .notFiled)
        XCTAssertFalse(effects.entries.contains("delete \(Self.gitLab.id)"))
    }

    func testABlankTokenIsNeverProbed() async {
        let effects = Effects()
        let outcome = await connector(effects).connect(Self.gitLab, token: "  \n")
        XCTAssertEqual(outcome, .notFiled)
        XCTAssertEqual(effects.entries, [])
    }

    /// Whether the token replaces one the index names cannot be told while
    /// the index will not read. Guessing "replacing" used to keep a new
    /// token whose index write then failed, with nothing on screen naming
    /// it, so the connect stops before the token leaves the sheet.
    func testNothingIsProbedOrSavedWhileTheIndexCannotBeRead() async {
        let effects = Effects()
        let outcome = await connector(effects, recorded: .failure(Refusal()))
            .connect(Self.gitLab, token: "glpat-test")
        XCTAssertEqual(outcome, .indexUnreadable)
        XCTAssertEqual(effects.entries, [])
    }
}
