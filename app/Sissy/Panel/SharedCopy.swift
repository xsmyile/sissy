import Foundation

/// The words every dialog, sheet and confirmation in the app shares, so a
/// button that means the same thing everywhere is spelt once.
enum DialogCopy {
    static let cancel = "Cancel"
}

/// What the Claude Code page says about its account list.
enum ClaudeAccountCopy {
    /// Said on the Claude Code page when the account index would not read and
    /// was set aside, which is why accounts it listed may be missing.
    static let indexSetAside =
        "Sissy could not read its list of saved accounts and kept it aside, so some may be "
        + "missing here · they come back as each one signs in"

    /// How many running sessions are on an account.
    static func sessions(_ count: Int) -> String {
        UsageFormat.agentCount(count, singular: "session", plural: "sessions")
    }

    /// An account in the account menu, which says which ones are in use.
    static func menuLabel(_ label: String, sessions count: Int) -> String {
        count > 0 ? "\(label) · in use · \(sessions(count))" : label
    }

    /// Said under the identity of the account being viewed, nil while no
    /// session is on it.
    static func inUseCaption(sessions count: Int) -> String? {
        count > 0 ? "In use · \(sessions(count))" : nil
    }
}

/// What spending a reset says, from the count on the page to the answer the
/// vendor gave.
///
/// Each answer is its own sentence because each asks something different of
/// the reader: a reset spent needs nothing, one that was not needed needs
/// patience, and one whose answer never arrived needs the one retry that is
/// safe to make.
enum LimitResetCopy {
    static let section = "Resets"
    static let use = "Use…"
    static let useHelp = "Spend one reset to put this account's windows back to zero"
    static let confirmTitle = "Use a reset now?"
    static let confirmAction = "Use reset"
    static let retry = "Try again"
    static let spending = "Spending a reset…"
    /// What the vendor calls the only kind of reset measured, when a reset
    /// arrives without a title of its own.
    static let defaultTitle = "Full reset"

    static func available(_ count: Int) -> String { "\(count) available" }

    /// The vendor's name for the soonest reset, and the day it lapses.
    static func caption(title: String?, expiresAt: Date?) -> String {
        let name = title ?? defaultTitle
        guard let expiresAt else { return name }
        return "\(name) · expires \(expiresAt.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// Who answers for the reset, by the name the user pays.
    private static func vendor(_ provider: String) -> String {
        provider == ProviderID.codex ? "OpenAI" : "Anthropic"
    }

    /// Added to the confirmation while the vendor counts no reset as usable,
    /// so the press is made knowing the vendor may decline it.
    static func notNeededYet(provider: String) -> String {
        "\(vendor(provider)) does not count one as needed yet and may decline it, which spends "
            + "nothing."
    }

    /// The windows a reset puts back to zero, as a sentence: both where the
    /// vendor does not say which, and by name where it does.
    private static func cleared(_ clears: [String]) -> String {
        guard !clears.isEmpty else { return "Both windows go back to zero." }
        guard clears.count > 1 else { return "\(clears[0]) goes back to zero." }
        return "\(clears.dropLast().joined(separator: ", ")) and \(clears[clears.count - 1]) go "
            + "back to zero."
    }

    /// The spend, and what waiting instead would cost: `naturalReset` is the
    /// longest window's own label and countdown, which is the one figure that
    /// tells a reset worth spending from one that buys an hour. `appliesNow`
    /// false adds that the vendor may decline it.
    static func confirmBody(
        available: Int, clears: [String] = [], naturalReset: (label: String, countdown: String)?,
        appliesNow: Bool, provider: String
    ) -> String {
        var sentences = ["\(cleared(clears)) This spends 1 of \(available)."]
        if let naturalReset {
            sentences.append("\(naturalReset.label) resets on its own \(naturalReset.countdown).")
        }
        if !appliesNow { sentences.append(notNeededYet(provider: provider)) }
        return sentences.joined(separator: " ")
    }

    static func outcome(_ outcome: LimitResetOutcome, provider: String) -> String {
        let vendor = vendor(provider)
        let credential = provider == ProviderID.codex ? "the Codex credential" : "Claude Code's sign-in"
        switch outcome {
        case .reset:
            return provider == ProviderID.codex
                ? "Done. Both windows are back to zero."
                : "Done. The windows it covers are back to zero."
        case .nothingToReset:
            return "Nothing was spent: \(vendor) says this account does not need a reset right now."
        case .noCredit: return "No reset left to spend on this account."
        case .cooldown:
            return "Nothing was spent: another reset was just started on this account. Try again "
                + "in a minute."
        case .offerChanged:
            let cli = provider == ProviderID.codex ? "Codex" : "Claude Code"
            return "Nothing was spent: \(cli) is signed in to another account now. Its "
                + "resets are on this page once it reads them."
        case .mayHaveLanded:
            return "The earlier try may have gone through. The windows above say whether it did."
        case .unconfirmed:
            return "No answer from \(vendor). Trying again cannot spend a second reset."
        case .refused: return "\(vendor) refused \(credential). Sign in again, then retry."
        case .unavailable:
            return provider == ProviderID.codex
                ? "Sissy has no Codex credential to spend a reset with."
                : "Sissy has no current Claude Code sign-in to spend a reset with. Run claude, "
                    + "then retry."
        }
    }
}

/// What naming an account says: the format picker under the account lists and
/// the rename their rows offer.
enum AccountNamingCopy {
    static let label = "Account names"
    static let caption = "How the panel names each account. Rename one from its ⋯ menu."
    static let renameItem = "Rename…"
    static let renameTitle = "Rename account"
    static let renameConfirm = "Rename"
    static let renameMessage = "Leave it empty to go back to the name Sissy picks."

    static func title(_ format: AccountNameFormat) -> String {
        switch format {
        case .automatic: return "Automatic"
        case .email: return "Email"
        case .nameAndOrganization: return "Name and organisation"
        }
    }
}

/// What linking an account says whichever vendor it is with: the words the
/// login window, the account menus and the add buttons share.
///
/// The vendor enums below keep only what differs, which is most of it; this
/// is the rest, so a button both vendors draw is worded once.
enum VendorLinkCopy {
    static let addTitle = "Add account…"
    static let unlinkItem = "Unlink…"
    static let link = "Link"
    static let retry = "Try again"
    static let done = "Done"
    static let failureTitle = "Sissy could not link that account"
    static let working = "Linking…"

    static func unlink(_ account: String) -> String { "Unlink \(account)" }

    static func chooseCaption(_ email: String?) -> String {
        let account = email ?? "That account"
        return "\(account) has more than one. Sissy reads the one you pick, and keeps reading it."
    }

    /// Why the vendor's page itself ended the sign-in, named by `vendor` as
    /// the page is: `claude.ai`, or `OpenAI`. A claude.ai login ends in a
    /// cookie rather than a redirect, so its decline is only reachable if the
    /// window is ever handed one.
    static func pageFailure(_ failure: VendorLoginWindow.PageFailure, vendor: String) -> String {
        switch failure {
        case .declined(let reason):
            return "\(vendor) did not complete the sign-in (\(reason)), so nothing was linked. "
                + "Try again, or cancel if you meant to stop."
        case .unreachable:
            return "The \(vendor) sign-in page could not be loaded. Check the connection and "
                + "try again."
        case .terminated:
            return "The \(vendor) sign-in page stopped before it finished. Try again."
        }
    }
}

/// What the Codex account link says.
///
/// Its own vocabulary rather than the Claude one's: what is linked is a
/// sign-in to OpenAI rather than a session on a website, what it is read for is
/// a workspace rather than an organisation, and what unlinking costs is
/// different: no CLI sign-in is involved, because Sissy never took one.
enum CodexAccountLinkCopy {
    /// What the sign-in page is called when it fails.
    static let vendor = "OpenAI"
    static let infoTitle = "How Sissy reads Codex accounts"

    static let detail =
        "Sissy reads the account Codex is signed into for free. Linking another signs in "
        + "to OpenAI once, in a window, and reads its limits beside it. Your terminal stays "
        + "on the account it is on."

    static let chooseLabel = "Which workspace?"

    static let unlinkHelp =
        "Forget this account's OpenAI sign-in. Codex itself is untouched."

    static func unlinkTitle(_ account: String) -> String {
        "Forget the OpenAI sign-in for \(account)?"
    }

    static let unlinkMessage =
        "Sissy stops reading this account's limits. Codex keeps whatever account it is "
        + "signed into, and you can link this one again from this window."

    static let unlinkConfirm = "Forget"

    /// Why an Unlink did not finish. The dialog that asked has closed by the
    /// time the keychain answers, so this is the only place it is said.
    static func unlinkFailure(_ why: AccountUnlink.Failure) -> String {
        switch why {
        case .credentialKept:
            return "The keychain would not delete this account's OpenAI sign-in, so it is still "
                + "linked. Unlock your login keychain and try again."
        case .nameKept:
            return "The OpenAI sign-in was deleted, but Sissy could not update its list of "
                + "linked accounts. The account is unlinked."
        }
    }

    /// Why a sign-in produced no account. Each names something different to
    /// do: a refusal is worth trying again, and a token naming no login is not
    /// something a retry can fix.
    static func failure(_ why: CodexOAuth.Failure) -> String {
        switch why {
        case .refused:
            return "OpenAI would not complete that sign-in. Try again."
        case .unidentified:
            return "That sign-in came back without naming an account, so there is nothing to link."
        case .interrupted:
            return "The sign-in did not finish. Try again."
        case .notFiled:
            return "You signed in, but the keychain would not save it, so nothing was linked. "
                + "Unlock your login keychain and try again."
        }
    }

    static let linkedToDefaultTitle = "Linked to the default workspace"

    /// What the window says when a link was filed on the workspace OpenAI
    /// defaults the login to, because the list of workspaces could not be
    /// read and so nobody was asked.
    static func linkedToDefault(email: String?, workspace: String?) -> String {
        let account = email ?? "this account"
        let which =
            workspace.map { "the one OpenAI signs it into by default, \($0)" }
            ?? "the one OpenAI signs it into by default"
        return "Sissy could not read which workspaces \(account) belongs to, so it linked "
            + "\(which). To read another, unlink it and link it again."
    }
}

/// What linking another Claude account says.
enum ClaudeAccountLinkCopy {
    /// What the sign-in page is called when it fails.
    static let vendor = "claude.ai"
    static let infoTitle = "How Sissy reads Claude accounts"

    static let detail =
        "Sissy reads the account Claude Code is signed into for free. Linking another "
        + "signs in to claude.ai once, in a window that closes itself, and reads its "
        + "limits and credits beside it."

    /// Why the account Sissy reads for free is whichever one the CLI is on,
    /// which is the half of the answer that only applies where Claude Code
    /// keeps a credential this Mac can read.
    ///
    /// It was a row of its own, titled `Limits source`, until 0.2.0: a
    /// statement of mechanism with no control on it, in a window where every
    /// other row is a control, costing 64 pt of a budget the tab was over.
    static let ownCredentialDetail =
        "Claude Code keeps its OAuth token in its own config directory, and it belongs to "
        + "whichever account is signed in there, so that is the account Sissy reads limits "
        + "for."

    static let chooseLabel = "Which organisation?"

    static let unlinkHelp =
        "Forget this account's claude.ai session. Claude Code's own sign-in is not touched."

    static func unlinkTitle(_ account: String) -> String {
        "Forget the claude.ai session for \(account)?"
    }

    static let unlinkMessage =
        "Sissy stops reading this account's limits and credits from claude.ai. Claude Code's "
        + "own sign-in is not touched. You can link the session again from this window."

    /// One word, because a longer one does not survive the alert's layout:
    /// every button is given the widest one's fitting width, and a row that
    /// passes ~110 pt is stacked vertically at full width instead. Measured
    /// 2026-09-17 on macOS 27, "Forget session" renders 114 pt and drew
    /// Cancel above it, where `CodexAccountLinkCopy` — the same dialog, one
    /// word shorter — drew both inline. The title already names what is
    /// being forgotten.
    static let unlinkConfirm = "Forget"

    /// Why an Unlink did not finish, for the reason the Codex one says it.
    static func unlinkFailure(_ why: AccountUnlink.Failure) -> String {
        switch why {
        case .credentialKept:
            return "The keychain would not delete this account's claude.ai session, so it is "
                + "still linked. Unlock your login keychain and try again."
        case .nameKept:
            return "The claude.ai session was deleted, but Sissy could not update its list of "
                + "linked accounts. The account is unlinked."
        }
    }

    static func failure(_ why: ClaudeWebAccountLink.Failure) -> String {
        switch why {
        case .unidentified:
            return "claude.ai would not say which account that session is for. Try again."
        case .noSubscription:
            return "That account is on no Claude plan Sissy can read limits for."
        case .interrupted:
            return "The sign-in was interrupted before Sissy could file it. Sign in again."
        }
    }
}

/// What Settings says when Claude Code has signed in under a config home
/// Sissy does not read.
///
/// A title that says what was found and one line under it that says what can
/// be done: sign in under the folder Sissy reads, or remove a sign-in left by
/// a folder no longer in use. It names the variable, because that is what the
/// user set and will recognise.
///
/// It describes the sign-in and never the account. The scan knows an item is
/// filed, not whose it is, so that account may well be signed in under the
/// default home or linked through claude.ai with its limits on screen.
enum ClaudeUnsupportedHomesCopy {
    static let title = "Claude Code sign-in not read"

    static func message(reading home: URL) -> String {
        let path = (home.path as NSString).abbreviatingWithTildeInPath
        return "Sissy meters only \(path), and reads CLAUDE_CONFIG_DIR only off a session it sees running. "
            + "If that folder is gone, remove its sign-in in Keychain Access."
    }
}

/// What the status switch says, and the part of it that moved into its ⓘ.
enum ProviderStatusCopy {
    static let label = "Provider status"
    static let caption = "Reads status.claude.com and status.openai.com."
    static let infoTitle = "What the status check reads"
    static let detail =
        "Sissy polls each vendor's own status page so the panel can say whether a provider "
        + "that has gone quiet is you or them. It carries no account, no sign-in and "
        + "nothing about your usage."
}
