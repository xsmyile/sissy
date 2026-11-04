import Foundation

/// Deletes, once, the copies of Claude credentials an earlier Sissy kept.
///
/// Until the account switch was removed, Sissy filed each account's OAuth
/// credential under a keychain service of its own. Nothing reads those items
/// now, and they hold refresh tokens, so left alone they stay on the Mac with
/// no way to remove them from inside the app.
///
/// Through `/usr/bin/security` rather than `KeychainAccess`, because every one
/// of these items was filed by that tool and only it is on their ACL. Measured
/// 2026-11-04 on macOS 27 with scratch items: an in-process `SecItemDelete`
/// under the panel suppression answered -25244 ("invalid attempt to change the
/// owner of this item") and left both items, while `security delete-generic-password` removed them in
/// about 40 ms each with no dialog, also for an item it was not on the ACL of.
///
/// A refusal or a keychain that cannot be asked leaves the record unset, so the
/// next launch tries again. Only this build's own namespace is touched: the
/// service is exact, so a `Claude Code-credentials` item can never match it.
struct ClaudeArchiveRemoval: Sendable {
    /// The record that the job is done, in Sissy's own support directory.
    static let recordFileName = "claude-archive-removed"
    /// Where the items were filed. The keychain account was the Claude uuid.
    static let service = SissyPaths.keychainService("claude-account")
    /// How many items one launch deletes. No Mac holds this many accounts, so
    /// this bounds a delete that reports success and removes nothing.
    static let itemLimit = 256

    /// How a run ended, for the caller's test and nothing else.
    enum Outcome: Equatable {
        /// The record was already there, and the keychain was not asked.
        case alreadyDone
        /// Nothing is left. `recorded` is false when the record would not write,
        /// which costs one more pass next launch and nothing else.
        case finished(removed: Int, recorded: Bool)
        /// The keychain stopped the run, or the limit did. No record written.
        case willRetry(removed: Int)
    }

    let recordURL: URL
    /// Deletes one item, answering false when none is left.
    var deleteOne: @Sendable () throws -> Bool

    static func live() -> Self {
        Self(
            recordURL: SissyPaths.appSupportDir.appendingPathComponent(recordFileName),
            deleteOne: { try ClaudeKeychainCLI.deleteOne(service: service) })
    }

    /// Runs the removal unless it has already finished. Blocks on one process
    /// per item, so it belongs off the main thread. Logs a count and never an
    /// account.
    @discardableResult
    func run() -> Outcome {
        guard !FileManager.default.fileExists(atPath: recordURL.path) else { return .alreadyDone }
        var removed = 0
        do {
            while removed < Self.itemLimit, try deleteOne() {
                removed += 1
            }
        } catch {
            sissyLog(
                "sissy: removed \(removed) saved Claude sign-ins, then the keychain stopped it "
                    + "(\(error)); trying again next launch")
            return .willRetry(removed: removed)
        }
        guard removed < Self.itemLimit else {
            sissyLog("sissy: removed \(removed) saved Claude sign-ins; trying again next launch")
            return .willRetry(removed: removed)
        }
        if removed > 0 { sissyLog("sissy: removed \(removed) saved Claude sign-ins") }
        return .finished(removed: removed, recorded: record())
    }

    private func record() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: recordURL, options: .atomic)
            return true
        } catch {
            let failure = error as NSError
            sissyLog(
                "sissy: could not record that the saved Claude sign-ins are gone "
                    + "(\(failure.domain) \(failure.code))")
            return false
        }
    }
}
