import CryptoKit
import Foundation

/// The login keychain, reached by running `/usr/bin/security`.
///
/// A keychain item's ACL names the *applications* allowed at its secret, and
/// Claude Code files its credential by shelling out to `security` — so the one
/// application on that list is `/usr/bin/security`. An in-process
/// `SecItemCopyMatching` is Sissy asking for an item it is not trusted on,
/// which macOS answers with the legacy Allow/Deny panel; and the grant that
/// panel gives dies at the next token refresh, because the CLI rewrites the
/// item and the ACL goes with it. Running the tool that is already on the ACL
/// costs no dialog, no grant and nothing that can go stale.
///
/// This gives Sissy nothing the user's own shell does not already have: one
/// `security find-generic-password -w` hands the same token to any process
/// running as this user. No entitlement, sandbox setting or privacy permission
/// changes any of it — the ACL is the item's, not the app's.
///
/// Measured 2026-09-15 against Claude Code 2.1.272 on macOS 27, from a process
/// that had never touched the item: a read of `Claude Code-credentials-a8264a74`
/// returned its 2 377 bytes and a write back to it exited 0, both with no panel.
enum ClaudeKeychainCLI {
    /// Why a call came back with nothing. Absence is not a failure — it is an
    /// account nobody has signed into — so it is its own case rather than a
    /// status every caller has to recognise.
    enum Failure: Error, Equatable {
        case noItem
        /// `security` exited non-zero for some other reason, carrying its code
        /// so a refusal can be told from a tool that would not run at all.
        case tool(Int32)
    }

    /// Service name Claude Code files the credential of a CLI started with no
    /// `CLAUDE_CONFIG_DIR` under.
    static let claudeService = "Claude Code-credentials"
    /// Service name Sissy files its own copy of an account's credential under.
    /// Its keychain account is the Claude account's uuid, so one item is one
    /// account for as long as that account exists.
    static let sissyAccountService = "com.radonforge.sissy.claude-account"

    private static let toolPath = "/usr/bin/security"
    /// `security` answers in milliseconds and has no dialog to wait behind
    /// here, so this bounds a wedged process rather than a user's decision.
    private static let timeout: TimeInterval = 5
    /// `security`'s own exit code for an item that is not in the keychain.
    private static let itemNotFound: Int32 = 44
    /// Hex characters of the digest Claude Code keeps. Its own constant, not a
    /// tuning knob: a different length addresses a different item.
    private static let suffixLength = 8
    private static let loginNamePattern = try? NSRegularExpression(
        pattern: "^[a-zA-Z0-9._-]+$")
    private static let fallbackLoginName = "claude-code-user"

    /// The secret filed under one service and account.
    static func read(service: String, account: String) throws -> Data {
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard result.status != itemNotFound else { throw Failure.noItem }
        guard result.status == 0 else { throw Failure.tool(result.status) }
        guard let text = String(bytes: result.output, encoding: .utf8) else {
            throw Failure.tool(result.status)
        }
        let blob = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blob.isEmpty else { throw Failure.noItem }
        return Data(blob.utf8)
    }

    /// Replaces the secret under one service and account, creating the item if
    /// it is not there. `-U` rather than a delete and an add: a delete that
    /// succeeded followed by an add that failed would sign the user out of a
    /// CLI they only asked to switch.
    ///
    /// The secret travels in `argv`, where a process running as this user can
    /// see it for the few milliseconds the tool lives. That is the exposure
    /// these items already have — any such process can read them back the same
    /// way — and `security` offers no form that takes the value on stdin.
    static func write(_ data: Data, service: String, account: String) throws {
        guard let secret = String(bytes: data, encoding: .utf8) else {
            throw Failure.noItem
        }
        let result = try run(
            ["add-generic-password", "-U", "-s", service, "-a", account, "-w", secret])
        guard result.status == 0 else { throw Failure.tool(result.status) }
    }

    /// Removes an item. A delete of something that is not there is a success:
    /// the caller asked for it to be gone.
    static func delete(service: String, account: String) throws {
        let result = try run(["delete-generic-password", "-s", service, "-a", account])
        if result.status == 0 || result.status == itemNotFound { return }
        throw Failure.tool(result.status)
    }

    /// Whether an item exists, asked without reading its secret.
    static func contains(service: String, account: String) -> Bool {
        let result = try? run(["find-generic-password", "-s", service, "-a", account])
        return result?.status == 0
    }

    /// The service name Claude Code files one config home's credential under.
    ///
    /// The default home is the exception the CLI itself makes: a session
    /// started with no `CLAUDE_CONFIG_DIR` reads the unsuffixed item, so that
    /// is the name for it rather than the hash of its path.
    ///
    /// Claude Code 2.1+ scopes the rest by config directory. Verified
    /// 2026-09-15 against the two homes on one Mac — `~/.claude` hashes to
    /// `8a380954` and `~/.claude-mastersoft` to `a8264a74`, and both items
    /// exist under exactly those names.
    static func claudeService(for home: URL) -> String {
        guard home != AccountDefaults.claudeHome else { return claudeService }
        return scopedClaudeService(for: home.path)
    }

    /// The scoped name for a directory path, by the CLI's own rule.
    static func scopedClaudeService(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(claudeService)-\(hex.prefix(suffixLength))"
    }

    /// The keychain account name Claude Code files under.
    ///
    /// Claude Code 2.1+ refuses a login name outside `[a-zA-Z0-9._-]` — an SSO
    /// address, say — and stores the item under a fixed name instead, so
    /// addressing the item by `$USER` alone would miss it on exactly those
    /// machines.
    static func claudeLoginName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let user = environment["USER"] ?? environment["USERNAME"] ?? NSUserName()
        let range = NSRange(user.startIndex..., in: user)
        guard let loginNamePattern,
            loginNamePattern.firstMatch(in: user, range: range) != nil
        else { return fallbackLoginName }
        return user
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, output)
    }
}
