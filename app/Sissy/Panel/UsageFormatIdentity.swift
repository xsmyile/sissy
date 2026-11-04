import Foundation

/// How the panel words an account of a vendor that has more than one.
extension UsageFormat {
    /// The count beside a vendor's name over its accounts, `3 accounts`.
    static func accountsCaption(_ count: Int) -> String {
        agentCount(count, singular: "account", plural: "accounts")
    }

    /// Said on the page of an account Sissy knows but holds no reading for:
    /// it has been seen signed in and has no live source, which is every
    /// account signed into this CLI that has not had a session linked to it.
    ///
    /// Worded as a state rather than an instruction while the control that
    /// would fix it does not exist yet. A sentence telling someone to press a
    /// button that is not there is worse than one that simply says what is
    /// true.
    /// The organisations of one account, labelled for someone choosing between
    /// them.
    ///
    /// The plan rather than the name, because claude.ai auto-generates the
    /// name of the organisation a personal plan comes with and does it in more
    /// than one shape — measured 2026-09-16, `<name>'s Individual Org` on one
    /// account and `<email>'s Organization` on another. Recognising that from
    /// the string would be a regex over the vendor's English copy; the plan is
    /// a field, and it is the same token the badge beside the account is
    /// already worded from.
    ///
    /// The name comes back only where it is needed: two organisations on one
    /// plan are told apart by nothing else, and an organisation whose plan the
    /// vendor did not name has only its name to go on.
    static func organizationChoices(
        _ organizations: [ClaudeWebOrganization]
    ) -> [(id: String, label: String)] {
        let labels = organizations.map { plan($0.plan, tier: nil, seat: nil)?.label }
        var counts: [String: Int] = [:]
        for label in labels.compactMap({ $0 }) { counts[label, default: 0] += 1 }
        return zip(organizations, labels).map { organization, label in
            guard let label else { return (organization.id, organization.name) }
            guard counts[label] == 1 else {
                return (organization.id, "\(label) · \(organization.name)")
            }
            return (organization.id, label)
        }
    }

    /// What a workspace is called where one has to be picked or named.
    ///
    /// The vendor's own name, with what it *is* beside it only when that adds
    /// something: a personal account and a workspace can share a name on one
    /// login, and `personal` is the word OpenAI itself uses. A structure this
    /// build does not know is printed humanised rather than dropped, the same
    /// rule a status token takes.
    static func workspaceLabel(_ workspace: CodexWorkspace) -> String {
        guard let structure = workspace.structure, !structure.isEmpty,
            structure.lowercased() != workspace.name.lowercased()
        else { return workspace.name }
        return "\(workspace.name) · \(humanised(structure))"
    }

    static let unlinkedAccountCaption =
        "Sissy has no live source for this account, so it cannot read its limits."

    // MARK: Git identities

    /// Who a commit in a repository would be signed as, or why nobody would.
    ///
    /// A failure is quoted rather than reworded: git's own sentence names the
    /// condition precisely — dubious ownership, a missing directory, a
    /// repository it will not open — and a paraphrase would lose the part the
    /// user has to act on.
    static func identityAuthor(_ reading: GitIdentityReading) -> String {
        switch reading {
        case .author(let author):
            return "\(author.name) <\(author.email)>"
        case .unset:
            return "No identity resolves here: git would refuse the commit"
        case .unreadable(let message):
            let first = message.split(separator: "\n").first.map(String.init) ?? message
            return first.isEmpty ? "Git could not read this repository" : first
        }
    }

    /// Where the address came from, which is the half that says what to change.
    static func identityOrigin(_ origin: GitConfigOrigin) -> String {
        "\(origin.scope) · \(origin.file)"
    }

    /// What the forge expects, for a repository that does not meet it.
    ///
    /// The count is what makes it evidence rather than an opinion: a row that
    /// merely says a name is wrong is a rule the user has to take on trust,
    /// where one that says how many repositories on that forge disagree can be
    /// checked.
    static func identityExpectation(_ verdict: GitIdentityVerdict, host: String?) -> String? {
        guard case .unexpected(let expected, let agreeing) = verdict else { return nil }
        let forge = host ?? "this forge"
        let repositories = agreeing == 1 ? "repository" : "repositories"
        return "\(forge) · \(agreeing) \(repositories) there commit as \(expected.name)"
    }

    /// The Overview's one line.
    ///
    /// A finding names one repository, because naming it is the whole of the
    /// remaining work, and counts several, because a list does not fit a line
    /// and the page behind it is where a list belongs. The feature's name and
    /// how many repositories the answer covers are the heading's, as of
    /// 2026-09-28: the line led with both when it was the one block on the page
    /// without a heading, and a finding naming a repository still truncated
    /// behind them. The verdict is two words after a middle dot for the same
    /// reason: measured 2026-09-29, a finding reading "owner/repo commits under
    /// an unexpected name" still truncated mid-sentence under the heading. "No
    /// findings" rather than "commit as expected": a repository with no remote
    /// or a lone account is read and not judged, and a line claiming it agrees
    /// would claim a verdict the page does not give.
    static func identityLine(unexpected: [String], checked: Int) -> String {
        switch unexpected.count {
        case 1: return "\(unexpected[0]) · unexpected name"
        case 2...: return "\(unexpected.count) repositories · unexpected name"
        default: return checked > 0 ? "No findings" : "Nothing read yet"
        }
    }

    /// The heading over the identity line, wherever the line is drawn.
    ///
    /// "Commit identity" rather than the page's own "Identities", because on
    /// the Forge tab it sits under the forges' logins, which are identities
    /// too: the heading has to name the check, not the noun.
    static let identitySectionLabel = "Commit identity"

    /// How many repositories the identity line's answer covers, for the end
    /// of its heading, where the projects' count sits on theirs. Nil before the
    /// first sweep, which has read none.
    static func identityCount(checked: Int) -> String? {
        guard checked > 0 else { return nil }
        return "\(checked) " + (checked == 1 ? "repository" : "repositories")
    }

    /// What the page says for a repository it holds no reading of: the one it
    /// was opened about, or every repository before the first sweep lands.
    static func identityUnread(focus: String?, anyRead: Bool) -> String? {
        if let focus { return "\(projectName(focus)) has not been read yet." }
        return anyRead ? nil : "No repository has been read yet."
    }

    /// What the identities page's header says under its title: that a
    /// re-read is running, or when the last one finished. Nil before the
    /// first sweep, which the page itself already says.
    static func identitiesReading(checkedAt: Date?, refreshing: Bool, now: Date) -> String? {
        if refreshing { return "checking…" }
        return checkedAt.map { statusAge(checkedAt: $0, now: now) }
    }

    /// What the Sessions tab's `Now` label says at its end: that a recount
    /// is running, or when the count on screen was taken.
    static func agentsReading(observedAt: Date?, refreshing: Bool, now: Date) -> String? {
        if refreshing { return "counting…" }
        return observedAt.map { "counted " + age(now.timeIntervalSince($0)) }
    }

    /// The sentence the page leads with once anything has been read.
    ///
    /// "Every repository" only when every one was judged and agrees: a
    /// repository with no remote or a lone account is read and not judged, and
    /// a sentence claiming it agrees would claim a verdict the page does not
    /// give — the reason the Overview's line says "no findings".
    static func identityVerdict(unexpected: Int, unjudged: Int) -> String {
        switch unexpected {
        case 1: return "1 repository commits under an unexpected name."
        case 2...: return "\(unexpected) repositories commit under an unexpected name."
        default:
            return unjudged == 0
                ? "Every repository commits under the name its forge expects."
                : "No repository commits under an unexpected name."
        }
    }

    /// One of the recap's counts, beside the mark it counts.
    static func identityCount(_ mark: UsagePanelSnapshot.IdentityMark, count: Int) -> String {
        "\(count) \(identityVerdictWord(mark))"
    }

    /// The recap's line for the repository a project row opened the page
    /// about, when that repository is under the fold.
    static func identityOpened(name: String, mark: UsagePanelSnapshot.IdentityMark) -> String {
        "Opened for \(name) · \(identityVerdictWord(mark))"
    }

    private static func identityVerdictWord(_ mark: UsagePanelSnapshot.IdentityMark) -> String {
        switch mark {
        case .unexpected: return "unexpected"
        case .agrees: return "as expected"
        case .unjudged: return "not judged"
        }
    }

    /// The control that opens the repositories the page did not need to show.
    static func identityDisclosure(all: Int) -> String {
        "Show all \(all)"
    }

    /// What the page says under its rows.
    ///
    /// The count is of what was read, not of what the ledger holds: a checkout
    /// that has been deleted is not a repository that went unchecked, and
    /// counting it would make the page claim a shortfall it does not have.
    static func identityFooter(checked: Int) -> String {
        "\(checked) \(checked == 1 ? "repository" : "repositories") checked"
    }
}
