import Foundation

/// Re-files the session an install imported before sessions were keyed by
/// account.
///
/// `ClaudeWebSessionStore` held one item under a fixed name, because there was
/// one session and nothing to tell it apart from. Sessions are now filed under
/// the Anthropic account uuid they belong to — the same key
/// `ClaudeAccountStore` files a CLI credential under, measured 2026-09-16 to
/// be one id across both vendors' endpoints — so the row a session draws and
/// the account it belongs to are the same row.
///
/// The old item names no account, and nothing on this Mac can say which one it
/// is: the session is opaque and only claude.ai knows whose it is. So the pass
/// costs one request, and that is why it is a pass rather than a rename.
enum ClaudeWebSessionAdoption {
    /// What a pass did, for the log and for the tests. Not an error type: none
    /// of these is something a caller acts on differently, and an install with
    /// no legacy session is the ordinary case rather than a failure.
    enum Outcome: Sendable, Equatable {
        /// No legacy item. Every install after this ships, and every one the
        /// pass has already run on.
        case nothingToAdopt
        case adopted(uuid: String)
        /// The session belongs to an account that already has one filed under
        /// its own key, which was linked through the window after the unkeyed
        /// item was written and is therefore the newer of the two. That one
        /// and its recorded link stand; the unkeyed copy is dropped.
        case alreadyLinked(uuid: String)
        /// claude.ai would not say whose the session is — offline, or a
        /// session that has ended. The item is left exactly where it was and
        /// the next launch tries again.
        case unidentified
        /// The keychain refused the move. Same treatment, for the same reason.
        case keychainRefused(ClaudeWebSessionStoreError)
        /// The item is there and this read was not allowed to have it, which
        /// is what a re-signed build meets. Emphatically not `nothingToAdopt`.
        case unreadable
    }

    /// The keychain half, behind closures.
    ///
    /// Injected for the same reason `ClaudeAccountStore.Secrets` is: writing a
    /// real session is the one piece of external I/O here, and what the pass
    /// *decides* — especially that it never ends holding none — has to be
    /// provable without the developer's own login keychain taking part.
    struct Store: Sendable {
        var read: @Sendable (String) -> ClaudeCredentialsLookup
        var write: @Sendable (String, String) throws -> Void
        var delete: @Sendable (String) throws -> Void

        static let keychain = Self(
            read: { account in
                ClaudeWebSessionStore.load(account: account, allowingInteraction: false)
            },
            write: { account, session in
                try ClaudeWebSessionStore.save(session, account: account)
            },
            delete: { account in try ClaudeWebSessionStore.delete(account: account) })
    }

    /// Runs the pass. Never writes over a session already filed under the
    /// account it identifies: that one was linked after the unkeyed item was
    /// written, so it is the newer, and its link may carry a chosen
    /// organisation the pass would replace with none. Idempotent, and safe to
    /// interrupt: the session is
    /// written under its new key before the old one is dropped, so the worst
    /// an interruption leaves is two copies of one session — which the next
    /// pass clears, because the legacy item is still there to be adopted.
    ///
    /// The drop is conditional on the holding key still containing the
    /// session this pass read, which is what keeps two passes from destroying
    /// an import. A pass is cancelled rather than joined when a new session
    /// arrives, and cancellation is observed at suspension points only: a pass
    /// suspended on its identifying request resumes after the new session has
    /// been filed, and an unconditional delete would take that session with
    /// it — leaving the import it was reported as succeeding gone from the
    /// Mac entirely.
    ///
    /// `identify` is the one part of this that leaves the machine.
    ///
    /// `remember` files what the session turned out to belong to. It costs
    /// this pass nothing — the identity is already in hand — and it is the
    /// only thing that names an adopted account on the panel: an account
    /// reached through a session alone has no archived CLI credential, so the
    /// account index holds nothing for it and its row would carry the raw
    /// Anthropic uuid. The organisation stays unrecorded, because nobody was
    /// asked and a capability-picked one is a guess rather than an answer.
    static func run(
        store: Store = .keychain,
        identify: @Sendable (String) async throws -> ClaudeAccountIdentity =
            ClaudeWebAccountProfile.resolve,
        remember: @Sendable (ClaudeWebLink) -> Void = { _ in }
    ) async -> Outcome {
        let session: String
        switch store.read(ClaudeWebSessionStore.unkeyedAccount) {
        case .found(let held):
            session = held.accessToken
        case .absent:
            return .nothingToAdopt
        case .interactionRequired, .denied, .unreadable, .timedOut:
            // Not `.nothingToAdopt`: the item is there and this read could not
            // have it. Silently reporting nothing to do would leave a session
            // unkeyed forever on a re-signed build with no line saying why.
            sissyLog(
                "sissy: the keychain would not release the unkeyed claude.ai session; "
                    + "it stays where it is until a read is allowed")
            return .unreadable
        }

        let identity: ClaudeAccountIdentity
        do {
            identity = try await identify(session)
        } catch {
            sissyLog(
                "sissy: claude.ai would not say which account the imported session belongs to "
                    + "(\(error)); leaving it where it is and trying again")
            return .unidentified
        }

        switch store.read(identity.uuid) {
        case .absent:
            break
        case .timedOut:
            sissyLog(
                "sissy: the keychain did not say whether the account already has a claude.ai "
                    + "session; leaving the unkeyed one where it is")
            return .unreadable
        case .found, .interactionRequired, .denied, .unreadable:
            return dropSuperseded(session, store: store, account: identity.uuid)
        }

        do {
            try store.write(identity.uuid, session)
            if case .found(let holding) = store.read(ClaudeWebSessionStore.unkeyedAccount),
                holding.accessToken == session
            {
                try store.delete(ClaudeWebSessionStore.unkeyedAccount)
            } else {
                sissyLog(
                    "sissy: a newer claude.ai session is waiting to be keyed; "
                        + "leaving it for the next pass")
            }
        } catch let failure as ClaudeWebSessionStoreError {
            sissyLog("sissy: could not file the claude.ai session under its account: \(failure)")
            return .keychainRefused(failure)
        } catch {
            sissyLog("sissy: could not file the claude.ai session under its account: \(error)")
            return .keychainRefused(.keychain(errSecIO))
        }
        remember(ClaudeWebLink(identity: identity, organization: nil))
        sissyLog("sissy: adopted the imported claude.ai session under its own account")
        return .adopted(uuid: identity.uuid)
    }

    /// Drops the unkeyed copy of a session whose account already has its own,
    /// on the same condition the move drops it: only while the holding key
    /// still holds the session this pass read.
    ///
    /// A delete the keychain refuses leaves the copy for the next pass, which
    /// meets the same keyed session and tries again; nothing is lost either
    /// way, because the keyed one is never touched.
    private static func dropSuperseded(
        _ session: String, store: Store, account: String
    ) -> Outcome {
        if case .found(let holding) = store.read(ClaudeWebSessionStore.unkeyedAccount),
            holding.accessToken == session
        {
            do {
                try store.delete(ClaudeWebSessionStore.unkeyedAccount)
            } catch {
                sissyLog("sissy: could not drop the superseded claude.ai session: \(error)")
            }
        }
        sissyLog("sissy: the account already has a linked claude.ai session; kept that one")
        return .alreadyLinked(uuid: account)
    }
}
