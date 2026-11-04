import Foundation

extension UsagePanelSnapshot {
    /// What a repository's commit identity is, as one row of the identities
    /// page.
    struct IdentityRow: Equatable, Identifiable {
        let id: String
        /// `owner/name`, the way the project row names the same repository,
        /// falling back to the directory for one whose remote names no forge.
        let name: String
        /// The full path, which is a client's name as often as not, so it
        /// stays on the hover exactly as it does on a project row.
        let path: String
        let mark: IdentityMark
        /// Who would sign a commit here, or why nobody would.
        let author: String
        /// Where the address was resolved from. Only on a row that needs
        /// correcting: on every other row it answers a question nobody asked.
        let origin: String?
        /// What the forge expects, and how many repositories say so.
        let expectation: String?
        /// The command that takes a repository's own override back out.
        ///
        /// Only where the override is local, because that is the only place
        /// unsetting changes the answer — a repository wearing the wrong name
        /// because a global rule gives it one has nothing of its own to
        /// remove, and offering the command there would be offering a no-op
        /// dressed as a fix. Nil too for a path `sh` quoting cannot make safe,
        /// which the reader refuses to build a command for at all.
        let fix: String?
    }

    /// How a repository's row is marked. A dash for `unjudged` rather than a
    /// tick or a warning: there is no reading to agree or disagree with, and
    /// the panel's own rule is that an absence of a measurement is drawn as
    /// one.
    enum IdentityMark: Equatable {
        case agrees
        case unexpected
        case unjudged
    }

    /// The Overview's identity line, and where it leads.
    struct IdentityLine: Equatable {
        let state: IdentityLineState
        let summary: String
        /// How many repositories were read, for the end of the heading.
        let count: String?
        /// The repository to open the page on, when exactly one is wrong.
        let repository: String?
    }

    /// What the Overview's identity line is saying, which decides its mark and
    /// its weight. `unread` is its own state rather than a `clean` with a zero
    /// in it: nothing read is the absence of a reading, never an agreement.
    enum IdentityLineState: Equatable {
        case unread
        case clean
        case findings
    }

    /// The identities page's rows: every repository Sissy could read a commit
    /// identity for, the findings first. Empty where there is no git to read
    /// with and until the first sweep has run, and the page then says nothing
    /// has been read rather than that everything agrees.
    ///
    /// Ordered by what the row says rather than by name: a page whose one
    /// wrong repository sorts to position nineteen is a page that has to be
    /// read rather than glanced at, and the rows that agree are the ones the
    /// user is not looking for.
    ///
    /// Not on the snapshot, which is built on every body pass of every page:
    /// the one page that draws these builds them.
    static func identityRows(_ identities: [RepositoryIdentity]) -> [IdentityRow] {
        identities.map(identityRow).sorted { left, right in
            guard left.mark == right.mark else { return rank(left.mark) < rank(right.mark) }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func rank(_ mark: IdentityMark) -> Int {
        switch mark {
        case .unexpected: return 0
        case .unjudged: return 1
        case .agrees: return 2
        }
    }

    private static func identityRow(_ identity: RepositoryIdentity) -> IdentityRow {
        var unexpected = false
        if case .unexpected = identity.verdict { unexpected = true }
        let origin = identity.origin
        return IdentityRow(
            id: identity.repository,
            name: identityName(identity),
            path: identity.repository,
            mark: mark(identity.verdict),
            author: UsageFormat.identityAuthor(identity.reading),
            origin: unexpected ? origin.map(UsageFormat.identityOrigin) : nil,
            expectation: UsageFormat.identityExpectation(identity.verdict, host: identity.host),
            fix: unexpected && origin?.scope == GitIdentityReader.localScope
                ? GitIdentityReader.unsetCommand(
                    repository: identity.repository, keys: identity.localKeys) : nil
        )
    }

    private static func identityName(_ identity: RepositoryIdentity) -> String {
        guard let remote = identity.remote else {
            return UsageFormat.projectName(identity.repository)
        }
        return "\(remote.owner)/\(remote.repository)"
    }

    private static func mark(_ verdict: GitIdentityVerdict) -> IdentityMark {
        switch verdict {
        case .agrees: return .agrees
        case .unexpected: return .unexpected
        case .unjudged: return .unjudged
        }
    }

    static func makeIdentityLine(_ identities: [RepositoryIdentity]) -> IdentityLine {
        let wrong = identities.filter {
            if case .unexpected = $0.verdict { return true }
            return false
        }
        let state: IdentityLineState =
            !wrong.isEmpty ? .findings : identities.isEmpty ? .unread : .clean
        return IdentityLine(
            state: state,
            summary: UsageFormat.identityLine(
                unexpected: wrong.map(identityName), checked: identities.count),
            count: UsageFormat.identityCount(checked: identities.count),
            repository: wrong.count == 1 ? wrong[0].repository : nil)
    }
}
