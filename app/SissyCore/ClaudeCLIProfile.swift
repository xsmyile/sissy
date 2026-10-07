import Foundation

/// The `oauthAccount` block of Claude Code's config file, which a switch has
/// to move along with the credential.
///
/// The CLI keeps the account it is signed in as there, and nothing but a
/// `/login` ever rewrites who that is. Read in the 2.1.292 bundle on
/// 2026-10-07: a token refresh merges only the profile's extras (the billing
/// type, the onboarding flags, the seat) into the block, and the bootstrap
/// fetch merges the vendor's account into it only when the vendor's
/// `account_uuid` is the block's own `accountUuid`. A switch that wrote only
/// the keychain therefore left the block naming the previous account for
/// good, and the CLI takes the organisation every organisation-scoped request
/// is made for from `oauthAccount.organizationUuid` before it asks the
/// profile endpoint, so the new account's token went out under the old
/// account's organisation.
///
/// The block is replaced rather than merged, and it carries only what Sissy
/// holds for the account: a field of the account switched away from (its
/// roles, its billing, its onboarding flags) left beside the new identity
/// would describe the new account with the old one's answers. The CLI fills
/// those back itself, because each path above merges into a block whose
/// `accountUuid` now matches: the bootstrap at its next start answers the
/// plan, the tiers and the organisation, and a token refresh fetches the
/// profile again precisely because `billingType` and the other extras are
/// missing. The organisation's id is left out when the identity was archived
/// before it was recorded, and then the CLI asks the profile endpoint with the
/// token it holds, which answers for the right account.
///
/// Written under the lock the CLI takes, the directory `<file>.lock`, and the
/// CLI reads the file again under that lock before each write it makes, so a
/// session that is already running lays its own changes over this block
/// rather than writing its copy back. A lock someone else holds is waited for
/// briefly and then given up on: breaking a stale lock is the CLI's call, not
/// Sissy's. The CLI's lock library takes a lock it finds older than ten seconds
/// to be abandoned, so Sissy checks before the rename and before the release
/// that the directory is still the one it made and younger than half that, and
/// a lock it may have lost is neither written under nor removed.
struct ClaudeCLIProfile: Sendable {
    enum Failure: Error, Equatable {
        /// The CLI held the file's lock for as long as Sissy waited.
        case locked
        /// The lock was taken over, or held too long to be sure it was not,
        /// before the write could land.
        case lockLost
        /// The file is there and is not a JSON object.
        case unreadable
        /// The rewritten file could not be put in place.
        case write(Int32)
    }

    /// Points the config file at one account, answering whether it had to be
    /// rewritten. Throws only where it could not be. The second argument is
    /// asked under the lock just before the file is replaced, and a false
    /// answer leaves the file as it is.
    var adopt: @Sendable (ClaudeAccountIdentity, () -> Bool) throws -> Bool

    /// Reads and writes nothing. What every registry gets unless it is built
    /// for the CLI's real home, so a suite can never touch the machine's file.
    static let inert = Self(adopt: { _, _ in false })

    /// The config file of the home Sissy meters, resolved on each call for the
    /// reason `ProviderHome.claudeProfileURL` is.
    static func live(home: ProviderHome) -> Self {
        Self(adopt: { identity, stillWanted in
            try adopt(identity, at: home.claudeProfileURL, while: stillWanted)
        })
    }

    static let blockKey = "oauthAccount"
    private static let accountKey = "accountUuid"
    private static let emailKey = "emailAddress"
    private static let organizationIDKey = "organizationUuid"
    private static let organizationNameKey = "organizationName"
    private static let organizationTypeKey = "organizationType"
    private static let rateLimitTierKey = "userRateLimitTier"
    private static let seatKey = "seatTier"

    /// What the CLI's lock directory is named after the file it guards.
    private static let lockSuffix = ".lock"
    private static let lockAttempts = 20
    private static let lockRetryMicroseconds: useconds_t = 50_000
    /// Half the ten seconds after which the CLI's lock library breaks a lock.
    private static let lockHoldLimit: TimeInterval = 5

    /// Whether the block already names the account, and the same organisation
    /// where both Sissy and the block name one. One that does is the CLI's own and richer than
    /// the one Sissy would write, so it is kept.
    static func names(_ identity: ClaudeAccountIdentity, in root: [String: Any]) -> Bool {
        guard let current = root[blockKey] as? [String: Any],
            current[accountKey] as? String == identity.uuid
        else { return false }
        guard let organization = identity.organizationUUID,
            let written = current[organizationIDKey] as? String
        else { return true }
        return written == organization
    }

    /// The config with its block pointed at `identity`, every other key kept.
    static func adopting(
        _ identity: ClaudeAccountIdentity, into root: [String: Any]
    ) -> [String: Any] {
        var updated = root
        updated[blockKey] = block(for: identity)
        return updated
    }

    /// The block as the CLI spells it, with every field Sissy does not hold
    /// for this account left out rather than guessed.
    static func block(for identity: ClaudeAccountIdentity) -> [String: Any] {
        let fields: [(String, String?)] = [
            (emailKey, identity.email),
            (organizationIDKey, identity.organizationUUID),
            (organizationNameKey, identity.organization),
            (organizationTypeKey, identity.organizationType),
            (rateLimitTierKey, identity.rateLimitTier),
            (seatKey, identity.seat),
        ]
        var block: [String: Any] = [accountKey: identity.uuid]
        for (key, value) in fields {
            if let value { block[key] = value }
        }
        return block
    }

    /// Rewrites the file at `url` for `identity`, answering whether it did.
    /// A file that is not there is left alone: the CLI writes one on its first
    /// run, and creating it here would be inventing a config for a CLI that
    /// has never started. A file already naming the account is answered
    /// without taking the lock, and checked again under it before the write.
    /// `stillWanted` is asked last, under the lock and just before the rename.
    @discardableResult
    static func adopt(
        _ identity: ClaudeAccountIdentity, at url: URL, while stillWanted: () -> Bool = { true }
    ) throws -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path),
            try !names(identity, in: config(at: target))
        else { return false }
        var wrote = false
        try holding(URL(fileURLWithPath: url.path + lockSuffix)) { isHeld in
            let root = try config(at: target)
            guard !names(identity, in: root) else { return }
            let rewritten = try JSONSerialization.data(
                withJSONObject: adopting(identity, into: root),
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            wrote = try replace(target, with: rewritten, whileHolding: isHeld, if: stillWanted)
        }
        return wrote
    }

    /// The config as a JSON object.
    private static func config(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadable
        }
        return root
    }

    /// Runs `body` holding the CLI's lock, which is a directory: creating it
    /// is the acquisition, so two holders cannot both succeed. `body` is
    /// handed the test of whether the lock is still Sissy's, timed from just
    /// before the `mkdir` that succeeded, and the release removes the
    /// directory only while that test holds: a lock left behind is one the
    /// CLI breaks as stale, where one removed could be the CLI's own.
    private static func holding(_ lock: URL, _ body: (() -> Bool) throws -> Void) throws {
        var attempt = 0
        var acquired = ProcessInfo.processInfo.systemUptime
        while mkdir(lock.path, 0o755) != 0 {
            guard errno == EEXIST else { throw Failure.write(errno) }
            attempt += 1
            guard attempt < lockAttempts else { throw Failure.locked }
            usleep(lockRetryMicroseconds)
            acquired = ProcessInfo.processInfo.systemUptime
        }
        let made = inode(of: lock)
        let isHeld = {
            made != nil && inode(of: lock) == made
                && ProcessInfo.processInfo.systemUptime - acquired < lockHoldLimit
        }
        defer { if isHeld() { rmdir(lock.path) } }
        try body(isHeld)
    }

    private static func inode(of url: URL) -> ino_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_ino : nil
    }

    /// Puts `data` at `target` in one rename, with the permissions the file
    /// had: the CLI keeps it readable by its owner only, and the copy is
    /// created with those bits rather than given them afterwards, so the
    /// file's contents are never readable by anyone else for a moment either.
    /// The copy reaches the disk before it replaces the original, so a crash
    /// in between leaves one whole file or the other. Answers false, with the
    /// original untouched, when `stillWanted` no longer holds at the rename.
    private static func replace(
        _ target: URL, with data: Data, whileHolding isHeld: () -> Bool,
        if stillWanted: () -> Bool
    ) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).sissy-\(UUID().uuidString)")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard descriptor >= 0 else { throw Failure.write(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard fchmod(descriptor, permissions) == 0 else { throw Failure.write(errno) }
            try handle.write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw Failure.write(errno) }
            try handle.close()
            guard stillWanted() else {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
            guard isHeld() else { throw Failure.lockLost }
            guard rename(staging.path, target.path) == 0 else { throw Failure.write(errno) }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return true
    }
}
