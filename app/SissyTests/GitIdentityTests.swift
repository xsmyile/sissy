import XCTest

@testable import Sissy

/// What a repository would sign a commit as, and which repositories disagree
/// with the forge they are pushed to.
///
/// The reader half runs against real repositories with a real `git`, because
/// the whole job is what git's own precedence answers — `includeIf`, scopes,
/// the gecos refusal — and a stub would be the second precedence engine this
/// module exists not to write. Each test owns a `HOME` and an
/// `XDG_CONFIG_HOME` of its own, so nothing here can read or write the
/// developer's configuration.
///
/// The isolation cannot reach git's **system** scope, so these tests assert on
/// values they set themselves rather than on the absence of a configuration
/// they cannot control.
final class GitIdentityTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var git: URL!
    private var previousXDG: String?

    override func setUpWithError() throws {
        git = try XCTUnwrap(GitIdentityReader.locate(), "no git on this machine to read with")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = Self.realPath(root)
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/git"), withIntermediateDirectories: true)
        previousXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", home.appendingPathComponent(".config").path, 1)
    }

    override func tearDownWithError() throws {
        if let previousXDG {
            setenv("XDG_CONFIG_HOME", previousXDG, 1)
        } else {
            unsetenv("XDG_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The reader

    func testReadsTheIdentityAGlobalConfigResolves() throws {
        writeGlobal("[user]\n\tname = Personal\n\temail = personal@example.com\n")
        let repository = try makeRepository("solo")
        let reading = try XCTUnwrap(read(repository))
        XCTAssertEqual(reading.author, GitAuthor(name: "Personal", email: "personal@example.com"))
        XCTAssertEqual(reading.origin?.scope, "global")
    }

    /// A repository's own `user.email` beats the global one, and the origin is
    /// resolved against the repository — git answers `file:.git/config`
    /// relative to the working directory, which names no file anyone can open.
    func testALocalOverrideWinsAndNamesAnAbsoluteFile() throws {
        writeGlobal("[user]\n\tname = Personal\n\temail = personal@example.com\n")
        let repository = try makeRepository("overridden")
        try run(["-C", repository, "config", "user.email", "local@example.com"])
        let reading = try XCTUnwrap(read(repository))
        XCTAssertEqual(reading.author?.email, "local@example.com")
        XCTAssertEqual(reading.origin?.scope, "local")
        XCTAssertEqual(
            reading.origin?.file, repository + "/.git/config",
            "a local origin has to name a path, not git's relative answer")
    }

    /// The case a folder rule cannot see and the reading must: `includeIf
    /// gitdir:` matches the git directory, so it is the repository's location
    /// that decides, never the checkout's.
    func testAnIncludeIfGitdirRuleIsResolvedByGit() throws {
        let work = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(
            atPath: work, withIntermediateDirectories: true)
        let profile = root.appendingPathComponent("work.gitconfig")
        try "[user]\n\tname = Work\n\temail = work@corp.example.com\n"
            .write(to: profile, atomically: true, encoding: .utf8)
        writeGlobal(
            """
            [user]
            \tname = Personal
            \temail = personal@example.com
            [includeIf "gitdir:\(work)/"]
            \tpath = \(profile.path)
            """)
        let inside = try makeRepository("work/inside")
        let outside = try makeRepository("elsewhere")
        XCTAssertEqual(try XCTUnwrap(read(inside)).author?.email, "work@corp.example.com")
        XCTAssertEqual(try XCTUnwrap(read(outside)).author?.email, "personal@example.com")
    }

    /// A name invented from the gecos field and the hostname is not an
    /// identity anyone commits under, and whether git refuses it is a property
    /// of the machine rather than of the repository: measured 2026-09-17, a
    /// Mac whose hostname yields no domain gets `unable to auto-detect email
    /// address` where a CI runner whose hostname ends `.local` was served
    /// `Anka <runner@…-F66C054AC5DC.local>` with status 0. So the reading is
    /// taken from the configuration, and answers the same on both.
    func testTheGuessGitMakesFromTheHostnameIsNeverAnIdentity() throws {
        writeGlobal("[core]\n\tautocrlf = input\n")
        let repository = try makeRepository("nameless")
        let reading = try XCTUnwrap(read(repository))
        XCTAssertEqual(reading.reading, .unset)
        XCTAssertNil(reading.author, "a guessed address must never reach a forge's electorate")
    }

    /// A name git guesses is still no identity: `user.name` alone leaves the
    /// address to the hostname, which is the half that has to be configured.
    func testANameWithNoAddressIsStillNothing() throws {
        writeGlobal("[user]\n\tname = Personal\n")
        let repository = try makeRepository("half-named")
        XCTAssertEqual(try XCTUnwrap(read(repository)).reading, .unset)
    }

    /// A configuration git could not read is not a repository with no
    /// identity. Only `--get-regexp`'s own no-match status means that; any
    /// other failure is a file that needs repairing, and saying "git would
    /// refuse the commit" would send the user looking in the wrong place.
    func testAConfigurationGitCannotReadIsNotAnAbsentIdentity() throws {
        let repository = try makeRepository("broken-config")
        writeGlobal("[user\n\tname = Broken\n")
        let reading = try XCTUnwrap(read(repository))
        guard case .unreadable(let message) = reading.reading else {
            return XCTFail("expected git's own refusal, got \(reading.reading)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// The reader's environment is built, not inherited: `GIT_AUTHOR_EMAIL`
    /// beats every file git resolves, so one in Sissy's own environment would
    /// make every repository on the machine read the same wrong answer.
    func testTheProcessEnvironmentCannotReachTheReading() throws {
        writeGlobal("[user]\n\tname = Personal\n\temail = personal@example.com\n")
        setenv("GIT_AUTHOR_EMAIL", "injected@example.com", 1)
        defer { unsetenv("GIT_AUTHOR_EMAIL") }
        let repository = try makeRepository("uninjected")
        XCTAssertEqual(try XCTUnwrap(read(repository)).author?.email, "personal@example.com")
    }

    /// A checkout that has been deleted is not a repository that went wrong.
    func testADirectoryThatIsGoneIsNotAFinding() throws {
        XCTAssertNil(read(root.appendingPathComponent("never-existed").path))
    }

    func testADirectoryThatIsNotARepositoryReportsWhatGitSaid() throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(
            at: plain.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let reading = try XCTUnwrap(read(plain.path))
        guard case .unreadable(let message) = reading.reading else {
            return XCTFail("expected git's own refusal, got \(reading.reading)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// What the sweep re-stats to know a reading can still stand. A process
    /// costs ~67 ms whatever it runs, so a round that re-read every repository
    /// regardless would be the feature's whole cost.
    func testAReadingNamesEveryFileItCouldChangeWith() throws {
        writeGlobal("[user]\n\tname = Personal\n\temail = personal@example.com\n")
        let repository = try makeRepository("watched")
        let sources = try XCTUnwrap(scan(repository)).sources
        XCTAssertTrue(
            sources.contains(repository + "/.git/config"),
            "a local user.email appearing has to be caught, and it is in no origin until it does")
        XCTAssertTrue(sources.contains(home.appendingPathComponent(".config/git/config").path))
    }

    /// An `includeIf` profile is a file the reading came out of, so editing it
    /// alone has to re-read — nothing else in the chain would have moved.
    func testAnIncludedProfileIsOneOfTheFilesWatched() throws {
        let profile = root.appendingPathComponent("work.gitconfig")
        try "[user]\n\tname = Work\n\temail = work@corp.example.com\n"
            .write(to: profile, atomically: true, encoding: .utf8)
        writeGlobal("[include]\n\tpath = \(profile.path)\n")
        let repository = try makeRepository("included")
        XCTAssertTrue(try XCTUnwrap(scan(repository)).sources.contains(profile.path))
    }

    /// A file that is not there yet stamps as absent, so creating it is a
    /// change rather than a stamp that happens to match.
    func testAnAbsentFileStampsAsAbsentAndItsCreationIsAChange() throws {
        let path = root.appendingPathComponent("later.gitconfig").path
        let before = GitIdentityReader.stamps(of: [path])
        XCTAssertEqual(before[path], .distantPast)
        try "[user]\n\temail = x@y\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(GitIdentityReader.stamps(of: [path]), before)
    }

    // MARK: The consensus

    func testOneDissenterIsTheOnlyRowThatChanges() {
        let work = GitAuthor(name: "Work", email: "work@corp")
        let personal = GitAuthor(name: "Personal", email: "me@home")
        let readings =
            (0..<8).map {
                reading("repo\($0)", host: "gitlab.example.com", owner: "team", author: work)
            } + [reading("stray", host: "gitlab.example.com", owner: "team", author: personal)]
        let judged = GitIdentityConsensus.judged(readings)
        XCTAssertEqual(
            judged.filter { $0.verdict == .agrees }.count, 8,
            "a forge is judged as a whole, so one wrong repository leaves the rest alone")
        let stray = try? XCTUnwrap(judged.first { $0.repository == "stray" })
        XCTAssertEqual(stray?.verdict, .unexpected(expected: work, agreeing: 8))
    }

    /// Two names with equal standing is a machine whose owner commits under
    /// both, and naming either the right one would invent the answer.
    func testATieExpectsNothing() {
        let readings = [
            reading("a", host: "forge", author: GitAuthor(name: "A", email: "a@x")),
            reading("b", host: "forge", author: GitAuthor(name: "A", email: "a@x")),
            reading("c", host: "forge", author: GitAuthor(name: "B", email: "b@x")),
            reading("d", host: "forge", author: GitAuthor(name: "B", email: "b@x")),
        ]
        XCTAssertTrue(GitIdentityConsensus.judged(readings).allSatisfy { $0.verdict == .unjudged })
    }

    /// One reading is not an agreement, so the first repository on a forge
    /// does not get to define it for every one after.
    func testAForgeWithOneRepositoryExpectsNothing() {
        let readings = [reading("only", host: "forge", author: GitAuthor(name: "A", email: "a@x"))]
        XCTAssertEqual(GitIdentityConsensus.judged(readings).first?.verdict, .unjudged)
    }

    func testARepositoryWithNoRemoteIsNeverJudged() {
        let author = GitAuthor(name: "A", email: "a@x")
        let readings = [
            reading("a", host: "forge", author: author),
            reading("b", host: "forge", author: author),
            reading("loose", host: nil, author: GitAuthor(name: "B", email: "b@x")),
        ]
        let judged = GitIdentityConsensus.judged(readings)
        XCTAssertEqual(judged.first { $0.repository == "loose" }?.verdict, .unjudged)
    }

    /// A repository git resolves no identity for cannot vote either, or a
    /// forge could be given an expectation by repositories that have none.
    func testARepositoryWithNoIdentityDoesNotCountTowardsAgreement() {
        let author = GitAuthor(name: "A", email: "a@x")
        let readings = [
            reading("a", host: "forge", author: author),
            RepositoryIdentity(
                repository: "b", reading: .unset, origin: nil,
                remote: remote(host: "forge"), verdict: .unjudged),
        ]
        XCTAssertEqual(
            GitIdentityConsensus.judged(readings).first { $0.repository == "a" }?.verdict,
            .unjudged)
    }

    /// The false finding the account-level electorate exists to prevent: one
    /// host, two organisations, the smaller one correctly scoped and simply
    /// outnumbered.
    func testTwoAccountsOnOneHostDoNotOutvoteEachOther() {
        let personal = GitAuthor(name: "Personal", email: "me@home")
        let work = GitAuthor(name: "Work", email: "me@corp")
        let readings =
            (0..<10).map {
                reading("mine\($0)", host: "github.com", owner: "me", author: personal)
            }
            + (0..<3).map {
                reading("theirs\($0)", host: "github.com", owner: "acme", author: work)
            }
        let judged = GitIdentityConsensus.judged(readings)
        XCTAssertTrue(
            judged.allSatisfy { $0.verdict == .agrees },
            "an organisation is not wrong for having fewer repositories than another")
    }

    /// And the coverage the fallback buys back: the first repository seen
    /// under an account has nobody of its own to be compared with, so a host
    /// every other repository agrees on answers for it.
    func testAHostEveryAccountAgreesOnJudgesAnAccountOfOne() {
        let work = GitAuthor(name: "Work", email: "work@corp")
        let personal = GitAuthor(name: "Personal", email: "me@home")
        let readings =
            (0..<4).map { reading("known\($0)", host: "gitlab.corp", owner: "team", author: work) }
            + [reading("fresh", host: "gitlab.corp", owner: "newteam", author: personal)]
        let judged = GitIdentityConsensus.judged(readings)
        XCTAssertEqual(
            judged.first { $0.repository == "fresh" }?.verdict,
            .unexpected(expected: work, agreeing: 4))
    }

    /// The fallback is unanimity, not a majority — a host that merely leans
    /// one way is the mixed host above.
    func testAHostThatIsOnlyMostlyOneNameIsNoFallback() {
        let personal = GitAuthor(name: "Personal", email: "me@home")
        let work = GitAuthor(name: "Work", email: "me@corp")
        let readings =
            (0..<10).map {
                reading("mine\($0)", host: "github.com", owner: "me", author: personal)
            }
            + (0..<3).map {
                reading("theirs\($0)", host: "github.com", owner: "acme", author: work)
            }
            + [reading("lonely", host: "github.com", owner: "solo", author: work)]
        XCTAssertEqual(
            GitIdentityConsensus.judged(readings).first { $0.repository == "lonely" }?.verdict,
            .unjudged)
    }

    /// A path `sh` quoting cannot make safe gets no command rather than an
    /// unquoted one on the clipboard.
    func testAnUnquotablePathIsOfferedNoCommand() {
        let keys = ["user.email"]
        XCTAssertNil(GitIdentityReader.unsetCommand(repository: "/repos/two\nlines", keys: keys))
        XCTAssertNotNil(GitIdentityReader.unsetCommand(repository: "/repos/it's fine", keys: keys))
    }

    /// The repository whose only override is `user.name` is the one the
    /// origin rule exists to catch, and a command that unset `user.email`
    /// first stopped there: git exits 5 on an absent key and `&&` goes no
    /// further. The command is run as the user would run it.
    func testTheCorrectionTakesOutANameOnlyOverride() throws {
        writeGlobal("[user]\n\tname = Personal\n\temail = personal@example.com\n")
        let repository = try makeRepository("name-only")
        try run(["-C", repository, "config", "user.name", "Stray"])
        let reading = try XCTUnwrap(read(repository))
        XCTAssertEqual(reading.localKeys, ["user.name"])
        let command = try XCTUnwrap(
            GitIdentityReader.unsetCommand(repository: repository, keys: reading.localKeys))
        XCTAssertEqual(try shell(command), 0, command)
        XCTAssertEqual(try XCTUnwrap(read(repository)).author?.name, "Personal")
    }

    /// An override written twice is still one override, and plain `--unset`
    /// refuses a key with more than one value.
    func testTheCorrectionTakesOutAKeySetMoreThanOnce() throws {
        writeGlobal("[user]\n\tname = Personal\n\temail = personal@example.com\n")
        let repository = try makeRepository("twice")
        try run(["-C", repository, "config", "user.email", "one@example.com"])
        try run(["-C", repository, "config", "--add", "user.email", "two@example.com"])
        let reading = try XCTUnwrap(read(repository))
        let command = try XCTUnwrap(
            GitIdentityReader.unsetCommand(repository: repository, keys: reading.localKeys))
        XCTAssertEqual(try shell(command), 0, command)
        XCTAssertEqual(try XCTUnwrap(read(repository)).author?.email, "personal@example.com")
    }

    // MARK: Helpers

    private func writeGlobal(_ contents: String) {
        try? contents.write(
            to: home.appendingPathComponent(".config/git/config"), atomically: true, encoding: .utf8)
    }

    private func makeRepository(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try run(["init", "-q", url.path])
        return url.path
    }

    private func read(_ repository: String) -> RepositoryIdentity? {
        scan(repository)?.identity
    }

    private func scan(_ repository: String) -> GitIdentityScan? {
        GitIdentityReader.read(repository: repository, remote: nil, git: git, home: home)
    }

    private func reading(
        _ name: String, host: String?, owner: String = "owner", author: GitAuthor
    ) -> RepositoryIdentity {
        RepositoryIdentity(
            repository: name, reading: .author(author), origin: nil,
            remote: host.map { remote(host: $0, owner: owner) }, verdict: .unjudged)
    }

    private func remote(host: String, owner: String = "owner") -> ProjectRemote {
        ProjectRemote(host: host, owner: owner, repository: "repository", page: nil)
    }

    /// The path git will compare an `includeIf gitdir:` pattern against.
    ///
    /// `realpath(3)` rather than `resolvingSymlinksInPath()`: Foundation
    /// deliberately answers `/var/folders/…` for the temporary directory where
    /// the real path is `/private/var/folders/…`, and git matches the real
    /// one — so a pattern built from Foundation's answer matches nothing.
    private static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Runs a command the way a pasted one runs, with this test's `HOME` and
    /// the real `git` first on the path.
    private func shell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "HOME": home.path,
            "PATH": git.deletingLastPathComponent().path + ":/usr/bin:/bin",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}

/// What the panel makes of the readings: which rows carry a correction, what
/// the Overview says, and in what order the page reads.
final class GitIdentityPanelTests: XCTestCase {
    private let work = GitAuthor(name: "Work", email: "work@corp")
    private let personal = GitAuthor(name: "Personal", email: "me@home")

    /// Unsetting a repository's own `user.email` only changes the answer where
    /// the repository set one. Offering the command against a global rule
    /// would be offering a no-op dressed as a fix.
    func testTheCorrectionIsOfferedOnlyAgainstALocalOverride() {
        let local = snapshot([
            identity("/repos/local", author: personal, scope: "local"),
            identity("/repos/a", author: work), identity("/repos/b", author: work),
        ])
        XCTAssertNotNil(local.identities.first { $0.id == "/repos/local" }?.fix)

        let global = snapshot([
            identity("/repos/global", author: personal, scope: "global"),
            identity("/repos/a", author: work), identity("/repos/b", author: work),
        ])
        XCTAssertNil(global.identities.first { $0.id == "/repos/global" }?.fix)
    }

    /// The origin is shown on a row that needs correcting and nowhere else: on
    /// a row that agrees it answers a question nobody asked.
    func testTheOriginRidesOnlyOnAFinding() {
        let rows = snapshot([
            identity("/repos/stray", author: personal, scope: "local"),
            identity("/repos/a", author: work, scope: "global"),
            identity("/repos/b", author: work, scope: "global"),
        ]).identities
        XCTAssertNotNil(rows.first { $0.id == "/repos/stray" }?.origin)
        XCTAssertNil(rows.first { $0.id == "/repos/a" }?.origin)
    }

    func testTheOverviewNamesOneRepositoryAndCountsSeveral() {
        let one = snapshot([
            identity("/repos/stray", author: personal),
            identity("/repos/a", author: work), identity("/repos/b", author: work),
        ]).identityLine
        XCTAssertEqual(one.state, .findings)
        XCTAssertEqual(one.summary, "owner/stray commits under an unexpected name")
        XCTAssertEqual(one.repository, "/repos/stray")

        let several = snapshot([
            identity("/repos/x", author: personal), identity("/repos/y", author: personal),
            identity("/repos/a", author: work), identity("/repos/b", author: work),
            identity("/repos/c", author: work),
        ]).identityLine
        XCTAssertEqual(several.summary, "2 repositories commit under an unexpected name")
        XCTAssertNil(
            several.repository, "a line that cannot name one repository opens the whole list")
    }

    /// The line is the page's door, so it stays on the Overview when every
    /// repository agrees, quiet and with the count of what was read.
    func testTheOverviewKeepsItsLineWhenEveryRepositoryAgrees() {
        let clean = snapshot([identity("/repos/a", author: work), identity("/repos/b", author: work)])
        XCTAssertEqual(clean.identityLine.state, .clean)
        XCTAssertEqual(clean.identityLine.summary, "Commit identity · no findings in 2 repositories")
        XCTAssertNil(clean.identityLine.repository)
    }

    /// Before the first sweep there is nothing to agree with, and the line
    /// says so rather than wearing a tick with a zero beside it.
    func testTheOverviewLineSaysNothingWasReadBeforeTheFirstSweep() {
        let unread = snapshot([]).identityLine
        XCTAssertEqual(unread.state, .unread)
        XCTAssertEqual(unread.summary, "Commit identity · nothing read yet")
    }

    /// A page whose one wrong repository sorts to the middle has to be read
    /// rather than glanced at.
    func testFindingsSortAboveEverythingElse() {
        let rows = snapshot([
            identity("/repos/aaa", author: work), identity("/repos/bbb", author: work),
            identity("/repos/zzz", author: personal),
            RepositoryIdentity(
                repository: "/repos/loose", reading: .author(personal), origin: nil,
                remote: nil, verdict: .unjudged),
        ]).identities
        XCTAssertEqual(rows.map(\.mark), [.unexpected, .unjudged, .agrees, .agrees])
    }

    /// Nothing read is not everything agreeing: the page is reachable from a
    /// project row before the first sweep lands, and must not reassure there.
    func testThePageSaysNothingHasBeenReadBeforeTheFirstSweep() {
        XCTAssertEqual(
            UsageFormat.identityUnread(focus: nil, anyRead: false),
            "No repository has been read yet.")
        XCTAssertNil(UsageFormat.identityUnread(focus: nil, anyRead: true))
    }

    /// The repository a row was clicked for answers for itself, even when the
    /// rest of the list has been read.
    func testTheRepositoryAskedAboutSaysItHasNotBeenRead() {
        XCTAssertEqual(
            UsageFormat.identityUnread(focus: "/repos/fresh", anyRead: true),
            "fresh has not been read yet.")
    }

    /// A repository that was not judged is not one that agrees, so the page
    /// does not say every repository does while one of them was not judged.
    func testTheRecapClaimsAgreementOnlyWhenEveryRepositoryWasJudged() {
        XCTAssertEqual(
            UsageFormat.identityVerdict(unexpected: 0, unjudged: 0),
            "Every repository commits under the name its forge expects.")
        XCTAssertEqual(
            UsageFormat.identityVerdict(unexpected: 0, unjudged: 1),
            "No repository commits under an unexpected name.")
    }

    func testTheRecapCountsItsFindings() {
        XCTAssertEqual(
            UsageFormat.identityVerdict(unexpected: 1, unjudged: 0),
            "1 repository commits under an unexpected name.")
        XCTAssertEqual(
            UsageFormat.identityVerdict(unexpected: 3, unjudged: 2),
            "3 repositories commit under an unexpected name.")
    }

    /// The repository a project row opened the page about is named with its
    /// verdict, so it does not stand alone as a row nobody asked for.
    func testTheRecapNamesTheRepositoryItWasOpenedFor() {
        XCTAssertEqual(
            UsageFormat.identityOpened(name: "xsmyile/sissy", mark: .agrees),
            "Opened for xsmyile/sissy · as expected")
        XCTAssertEqual(UsageFormat.identityCount(.unjudged, count: 2), "2 not judged")
    }

    /// A press that changed no row still moves the header, which is what
    /// tells it apart from a button that did nothing.
    func testTheHeaderSaysCheckingUntilTheSweepLands() {
        let now = Date()
        XCTAssertEqual(
            UsageFormat.identitiesReading(checkedAt: now, refreshing: true, now: now),
            "checking…")
        XCTAssertEqual(
            UsageFormat.identitiesReading(
                checkedAt: now.addingTimeInterval(-180), refreshing: false, now: now),
            "checked 3m ago")
        XCTAssertNil(UsageFormat.identitiesReading(checkedAt: nil, refreshing: false, now: now))
    }

    private func snapshot(_ identities: [RepositoryIdentity]) -> UsagePanelSnapshot {
        UsagePanelSnapshot.make(
            frame: FrameData(
                tokens: 0, cost: 0, burn: nil, providers: [], keepAwake: .off,
                identities: GitIdentityConsensus.judged(identities)))
    }

    private func identity(
        _ path: String, author: GitAuthor, scope: String? = nil, host: String = "forge.example.com"
    ) -> RepositoryIdentity {
        RepositoryIdentity(
            repository: path,
            reading: .author(author),
            origin: scope.map { GitConfigOrigin(scope: $0, file: path + "/.git/config") },
            remote: ProjectRemote(
                host: host, owner: "owner",
                repository: (path as NSString).lastPathComponent, page: nil),
            verdict: .unjudged,
            localKeys: scope == "local" ? ["user.email"] : [])
    }
}
