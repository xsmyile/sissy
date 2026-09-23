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
/// that had never touched the item: a read of a scoped credential item returned
/// its 2 377 bytes and a write back to it exited 0, both with no panel.
enum ClaudeKeychainCLI {
    /// Why a call came back with nothing. Absence is not a failure — it is an
    /// account nobody has signed into — so it is its own case rather than a
    /// status every caller has to recognise.
    enum Failure: Error, Equatable {
        case noItem
        /// `security` exited non-zero for some other reason, carrying its code
        /// so a refusal can be told from a tool that would not run at all.
        case tool(Int32)
        /// `security` did not answer: it could not be started, or it outlived
        /// its budget and was stopped. Nothing is known about the item.
        case unavailable
    }

    /// `security`'s exit codes for a keychain that cannot be used right now
    /// rather than an item that refused: 36 is `errSecInteractionNotAllowed`
    /// (the keychain is locked and no dialog may be shown) and 51 is
    /// `errSecAuthFailed`, each truncated to the eight bits an exit status
    /// carries. Neither is fixed by signing in again, so neither may be worded
    /// as if it were.
    static let unavailableStatuses: Set<Int32> = [36, 51]

    /// Service name Claude Code files the credential of a CLI started with no
    /// `CLAUDE_CONFIG_DIR` under.
    static let claudeService = "Claude Code-credentials"
    /// Service name Sissy files its own copy of an account's credential under.
    /// Its keychain account is the Claude account's uuid, so one item is one
    /// account for as long as that account exists.
    static let sissyAccountService = SissyPaths.keychainService("claude-account")

    private static let toolPath = "/usr/bin/security"
    /// `security` answers in milliseconds and has no dialog to wait behind
    /// here, so this bounds a wedged process rather than a user's decision.
    private static let timeout: TimeInterval = 5
    /// `security`'s own exit code for an item that is not in the keychain.
    private static let itemNotFound: Int32 = 44
    /// Hex characters of the digest Claude Code keeps. Its own constant, not a
    /// tuning knob: a different length addresses a different item.
    static let suffixLength = 8
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
    ///
    /// Throws where the lookup itself failed, because a keychain that could
    /// not be asked is not one without the item.
    static func contains(service: String, account: String) throws -> Bool {
        let result = try run(["find-generic-password", "-s", service, "-a", account])
        if result.status == itemNotFound { return false }
        guard result.status == 0 else { throw Failure.tool(result.status) }
        return true
    }

    /// The service name Claude Code files one config home's credential under.
    ///
    /// The default home is the exception the CLI itself makes: a session
    /// started with no `CLAUDE_CONFIG_DIR` reads the unsuffixed item, so that
    /// is the name for it rather than the hash of its path.
    ///
    /// Claude Code 2.1+ scopes the rest by config directory. Verified
    /// 2026-09-15 against the two homes on one Mac: each item existed under
    /// exactly the name this rule produces for its own path.
    ///
    /// Which home is the default is decided on standardized paths. A URL
    /// built for a directory that exists carries a trailing slash and one
    /// built before it existed does not, so comparing the URLs themselves
    /// addressed the scoped item for `~/.claude` on a Mac where the directory
    /// was created after Sissy launched.
    static func claudeService(for home: URL) -> String {
        guard !AccountDefaults.isDefaultClaudeHome(home) else { return claudeService }
        return scopedClaudeService(for: home.path)
    }

    /// The other service names Claude Code may keep one config home's
    /// credential under, beside the one `claudeService(for:)` names.
    ///
    /// The default home is the case with two. Measured 2026-09-21 on macOS 27:
    /// `Claude Code-credentials` (created 2026-04-28) and
    /// `Claude Code-credentials-8a380954` — the scoped name for
    /// `~/.claude` — both existed for it and carried the same modification
    /// date to the second, the CLI having rewritten the pair together. The
    /// scoped one was created 2026-09-16, after the measurement
    /// `claudeService(for:)` is written from, so a build reading that rule
    /// alone addresses half of what the CLI now keeps. Which of the two a
    /// `claude` reads first is its business, so a switch reaching only one
    /// leaves the other naming the account the user just left.
    ///
    /// The pair does not stay in step. Measured 2026-09-23 against Claude
    /// Code 2.1.280: a `claude /login` wrote the unscoped item alone at
    /// 09:20:38Z and left this one on the previous account, and the CLI went
    /// on running as the account the unscoped item named. So this name is a
    /// sibling rather than a peer: `ClaudeCLISlot` reads it only when the
    /// unscoped item holds nothing, and a switch writes it only where it
    /// already holds a credential.
    static func siblingClaudeServices(for home: URL) -> [String] {
        guard AccountDefaults.isDefaultClaudeHome(home) else { return [] }
        return [scopedClaudeService(for: home.path)]
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

    /// One `security` invocation, bounded.
    ///
    /// Standard error goes to the null device rather than a pipe: nothing here
    /// reads it, and a pipe nobody drains blocks the child once the kernel
    /// buffer fills. A tool that would not start and one the watchdog had to
    /// stop are both `unavailable`: neither is an answer about the item.
    private static func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.unavailable
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit else { throw Failure.unavailable }
        return (process.terminationStatus, output)
    }
}
