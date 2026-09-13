import XCTest

@testable import Sissy

/// Against real files, never the real ones: every path here is injected, and
/// the installer has no default that resolves to a live configuration — the
/// test host runs against this machine's own `Sissy-Dev` tree, and a default
/// argument would put these writes into the user's actual settings.
final class AgentHookInstallerTests: XCTestCase {
    private var root: URL!
    private var bundledScript: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-hooks-\(UUID().uuidString)")
        bundledScript = root.appendingPathComponent("bundle/session-start.sh")
        try FileManager.default.createDirectory(
            at: bundledScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: bundledScript, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnAbsentConfigurationIsCreatedWithTheEntry() throws {
        let (installer, target) = make("absent")

        XCTAssertEqual(installer.install(bundledScript: bundledScript)[target], .written)

        XCTAssertTrue(commands(in: target.url).contains { $0.contains(AgentHookInstaller.marker) })
    }

    func testTheScriptAndInboxAreLaidDownPrivately() throws {
        let (installer, _) = make("private")

        installer.install(bundledScript: bundledScript)

        XCTAssertEqual(try mode(of: installer.scriptURL), 0o700)
        XCTAssertEqual(try mode(of: installer.inboxURL), 0o700)
    }

    /// An ordinary launch re-affirms and must write nothing at all — the file
    /// belongs to another program and every rewrite is a chance to lose one of
    /// its updates.
    func testReaffirmingWritesNothing() throws {
        let (installer, target) = make("idempotent")
        installer.install(bundledScript: bundledScript)
        let before = try Data(contentsOf: target.url)

        XCTAssertEqual(installer.install(bundledScript: bundledScript)[target], .unchanged)

        XCTAssertEqual(try Data(contentsOf: target.url), before)
    }

    /// Three programs already keep hooks in this file on the developer's own
    /// machine. Sissy's line is one of several, never the file.
    func testEverythingElseInTheFileSurvives() throws {
        let (installer, target) = make("coexist")
        try writeConfiguration(
            [
                "theme": "dark",
                "permissions": ["allow": ["Bash(ls:*)"]],
                "hooks": [
                    "SessionStart": [["hooks": [["type": "command", "command": "orca-hook.sh"]]]],
                    "Stop": [["hooks": [["type": "command", "command": "paseo stop"]]]],
                ],
            ], to: target.url)

        installer.install(bundledScript: bundledScript)

        let root = try configuration(of: target.url)
        XCTAssertTrue(commands(in: target.url).contains("orca-hook.sh"))
        XCTAssertEqual(commands(in: target.url).count, 2)
        XCTAssertNotNil((root["hooks"] as? [String: Any])?["Stop"])
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual(
            ((root["permissions"] as? [String: Any])?["allow"] as? [String])?.first, "Bash(ls:*)")
    }

    func testTheFilesOwnPermissionsAreKept() throws {
        let (installer, target) = make("mode")
        try writeConfiguration([:], to: target.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: target.url.path)

        installer.install(bundledScript: bundledScript)

        XCTAssertEqual(try mode(of: target.url), 0o600)
    }

    func testRemovalTakesOnlySissysLineAndItsOwnFiles() throws {
        let (installer, target) = make("removal")
        try writeConfiguration(
            ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "orca-hook.sh"]]]]]],
            to: target.url)
        installer.install(bundledScript: bundledScript)

        XCTAssertEqual(installer.remove()[target], .removed)

        XCTAssertEqual(commands(in: target.url), ["orca-hook.sh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.inboxURL.path))
    }

    /// Claude Code rewrites this file itself, from memory, while Sissy may be
    /// re-affirming. The identity the write is pinned to comes from `fstat` on
    /// the descriptor the bytes were read through, so a rewrite that lands in
    /// between is caught rather than confirmed — the earlier spelling stat'd
    /// the path again after the read and would have described, and then
    /// overwritten, the newer file.
    func testAConcurrentRewriterNeverLosesItsChangeOrAForeignEntry() throws {
        let (installer, target) = make("race")
        try writeConfiguration(
            ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "orca-hook.sh"]]]]]],
            to: target.url)
        let stop = DispatchSemaphore(value: 0)
        let rewriter = Thread {
            var revision = 0
            while stop.wait(timeout: .now()) == .timedOut {
                revision += 1
                guard let data = try? Data(contentsOf: target.url),
                    var document = (try? JSONSerialization.jsonObject(with: data))
                        as? [String: Any]
                else { continue }
                document["revision"] = revision
                let staging = target.url.deletingLastPathComponent()
                    .appendingPathComponent("rewriter-\(revision).tmp")
                try? JSONSerialization.data(withJSONObject: document).write(to: staging)
                _ = rename(staging.path, target.url.path)
            }
        }
        rewriter.start()
        defer { stop.signal() }

        for _ in 0..<60 {
            _ = installer.install(bundledScript: bundledScript)
            _ = installer.remove()
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: try Data(contentsOf: target.url)))
            XCTAssertTrue(commands(in: target.url).contains("orca-hook.sh"))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: target.url.deletingLastPathComponent().path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.contains(".sissy-") })
    }

    /// Repairing another program's configuration is not Sissy's to attempt, and
    /// a file being mid-edit is the likeliest reason it will not parse.
    func testAConfigurationThatWillNotParseIsLeftExactlyAsItWas() throws {
        let (installer, target) = make("broken")
        let garbage = "{ \"hooks\": { oops, }\n"
        try garbage.write(to: target.url, atomically: true, encoding: .utf8)

        XCTAssertEqual(installer.install(bundledScript: bundledScript)[target], .unreadable)

        XCTAssertEqual(try String(contentsOf: target.url, encoding: .utf8), garbage)
    }

    /// A dotfiles-managed settings file is usually a symlink, and an atomic
    /// write through one replaces the link with a regular file.
    func testASymlinkedConfigurationKeepsItsLink() throws {
        let (installer, target) = make("symlink")
        let real = root.appendingPathComponent("symlink/dotfiles/settings.json")
        try FileManager.default.createDirectory(
            at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: target.url)
        try FileManager.default.createSymbolicLink(at: target.url, withDestinationURL: real)

        installer.install(bundledScript: bundledScript)

        let attributes = try FileManager.default.attributesOfItem(atPath: target.url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertTrue(commands(in: real).contains { $0.contains(AgentHookInstaller.marker) })
    }

    /// The command is executed by two other programs at every session start,
    /// and the path in it comes from the account's home — which `getpwuid`
    /// answers honestly and `NSHomeDirectory()` does not, following
    /// `CFFIXED_USER_HOME` instead.
    func testAHostilePathIsQuotedRatherThanExecuted() throws {
        let witness = root.appendingPathComponent("executed")
        let hostile = [
            "/tmp/x'$(touch \(witness.path))'", "/tmp/o'brien", "/tmp/a b",
            #"/tmp/back\slash"#, "/tmp/dollar$HOME", "/tmp/tick`id`",
        ]

        for path in hostile {
            let installer = AgentHookInstaller(
                stateDirectory: URL(fileURLWithPath: path), targets: [])
            let command = try XCTUnwrap(installer.shellCommand())
            XCTAssertTrue(AgentHookInstaller.isParsable(command))
            XCTAssertTrue(
                command.contains(try XCTUnwrap(AgentHookInstaller.quoted(installer.scriptURL.path))))
            let outcome = runShell(command)
            XCTAssertEqual(outcome.status, 0)
            XCTAssertTrue(outcome.output.isEmpty)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path))
    }

    /// A newline would split the line the marker identifies, so the entry could
    /// never be found again to remove.
    func testAPathWithANewlineRefusesToInstall() {
        let installer = AgentHookInstaller(
            stateDirectory: URL(fileURLWithPath: "/tmp/a\nb"), targets: [])

        XCTAssertNil(installer.shellCommand())
    }

    func testTheAccountsOwnHomeIsAnswered() throws {
        let home = try XCTUnwrap(AgentHookInstaller.userHome)

        XCTAssertTrue(home.path.hasPrefix("/"))
        XCTAssertEqual(AgentHookInstaller.targets(home: home).count, 2)
    }

    private func make(_ name: String) -> (AgentHookInstaller, AgentHookTarget) {
        let configuration = root.appendingPathComponent("\(name)/home/.claude/settings.json")
        try? FileManager.default.createDirectory(
            at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = AgentHookTarget(name: "Claude Code", url: configuration)
        let installer = AgentHookInstaller(
            stateDirectory: root.appendingPathComponent("\(name)/state"), targets: [target])
        return (installer, target)
    }

    private func writeConfiguration(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)
    }

    private func configuration(of url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    private func commands(in url: URL) -> [String] {
        let root = (try? configuration(of: url)) ?? [:]
        let groups =
            ((root["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue
    }

    private func runShell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try? process.run()
        try? input.fileHandleForWriting.close()
        let captured = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: captured, as: UTF8.self))
    }
}
