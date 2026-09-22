import Foundation

/// The name and address a commit would be signed with.
struct GitAuthor: Sendable, Equatable, Hashable {
    let name: String
    let email: String
}

/// Where git resolved a value from: the scope it belongs to, and the file it
/// was read out of.
///
/// The file is the half that makes a reading actionable — `local` names a
/// scope, and a correction has to name a path. Git answers a local origin
/// relative to the working directory (measured: `file:.git/config`), so it is
/// resolved against the repository before it is kept.
struct GitConfigOrigin: Sendable, Equatable {
    let scope: String
    let file: String
}

/// What git answered when asked who would sign a commit in a repository.
enum GitIdentityReading: Sendable, Equatable {
    case author(GitAuthor)
    /// Git resolves no identity here and would refuse the commit. Its own
    /// guess from the gecos field is deliberately not reported as an answer,
    /// because git does not accept it as one either: measured, `git var
    /// GIT_AUTHOR_IDENT` exits 128 with `unable to auto-detect email address
    /// (got 'davide@blackbird.(none)')` rather than returning the guess.
    case unset
    /// Git could not be asked, and this is what it said. A path that is not a
    /// repository, a checkout on an unmounted disk, and a repository git
    /// refuses over its ownership all land here.
    case unreadable(String)
}

/// Whether a repository's identity is the one the forge it is pushed to
/// implies.
enum GitIdentityVerdict: Sendable, Equatable {
    /// The identity is the one this forge's other repositories commit under.
    case agrees
    /// It is not, and `agreeing` repositories on the same forge say so.
    case unexpected(expected: GitAuthor, agreeing: Int)
    /// There is nothing to compare against: no remote, no identity, or a
    /// forge whose repositories do not agree among themselves. An absence of
    /// a reading, never a reading of zero.
    case unjudged
}

/// The identity a commit in one repository would carry, and what Sissy makes
/// of it.
struct RepositoryIdentity: Sendable, Equatable, Identifiable {
    var id: String { repository }
    /// The repository, which is the main checkout a worktree folds into. A
    /// worktree is not a separate answer here — `includeIf gitdir:` matches
    /// the git directory, which lives under the repository whatever path the
    /// checkout sits at.
    let repository: String
    let reading: GitIdentityReading
    /// The most local file that set a `user.*` key, which is the one a
    /// correction has to name. Nil when nothing set either.
    let origin: GitConfigOrigin?
    /// The forge the repository is pushed to, which is what the verdict is
    /// formed against. Nil for a repository with no remote, or one whose
    /// remote names a path on this Mac.
    ///
    /// The whole remote rather than its host alone, so the page names a
    /// repository the way the project row beside it does — `owner/name`, with
    /// the forge's own mark — instead of inventing a second label for the
    /// same repository out of its directory.
    let remote: ProjectRemote?
    let verdict: GitIdentityVerdict
    /// The `user.*` keys the repository's own configuration sets, which are
    /// the ones a correction can take out. Named rather than assumed:
    /// `git config --unset` exits 5 on a key that is not there, so a command
    /// that unset both regardless stopped at the first absent one.
    var localKeys: [String] = []

    var host: String? { remote?.host }

    /// The electorate this repository votes in: the account on the forge
    /// rather than the forge. Nil where there is no remote to name one.
    var forge: String? { remote.map { "\($0.host)/\($0.owner)" } }

    func with(verdict: GitIdentityVerdict) -> Self {
        Self(
            repository: repository, reading: reading, origin: origin, remote: remote,
            verdict: verdict, localKeys: localKeys)
    }

    var author: GitAuthor? {
        guard case .author(let author) = reading else { return nil }
        return author
    }
}

/// Decides, from readings alone, which repositories commit under a name their
/// forge does not expect.
///
/// **The remote is the rule, not the folder.** Measured 2026-09-17 across the
/// 23 live repositories one machine's ledger names: the remote classifies 23 of
/// 23, where a folder root classifies 15 — the other 8 sit outside every root
/// and are correct only because the default identity happens to be theirs. The
/// remote is also the only signal that reaches the case this exists for, a
/// work repository cloned wherever and committed to under a personal name; a
/// `gitdir:` rule cannot see it, because the checkout is not where the rule
/// looks.
///
/// **The electorate is the account on the forge, not the forge.** Grouping by
/// host alone puts every organisation on `github.com` in one vote, so a user
/// with ten personal repositories and three correctly-scoped employer ones has
/// the three flagged for being outnumbered — a false finding against a setup
/// that is right, which is the one failure this must not have. A detector that
/// is silent until something is wrong trades coverage for that silence every
/// time: saying nothing costs a finding, saying the wrong thing costs the
/// feature.
///
/// **A host whose accounts all agree is the fallback**, and only where it is
/// unanimous. It is what still catches the first repository Sissy sees under a
/// new account — the Ale case, a work repository whose account has no other
/// row to compare against — while the mixed host above has no unanimity to
/// fall back on and each account answers for itself.
///
/// **The rule is learned rather than configured.** There is no profile to
/// create and no root to assign: an account whose repositories agree is one
/// with an expectation, and the one that disagrees is the finding. That is
/// also why an account Sissy knows one repository under says nothing on its
/// own — there is no agreement to disagree with, and inventing one from a
/// single reading would make the first repository define it for every one
/// after.
enum GitIdentityConsensus {
    /// How many repositories have to commit under one name before that name is
    /// what their forge expects. One is a reading; two is the smallest thing
    /// that can be called agreement.
    static let minimumAgreement = 2

    /// Judges every reading, and returns them carrying their verdicts.
    ///
    /// An electorate is judged as a whole rather than each repository against
    /// its own neighbours: measured against the alternative, one wrong
    /// repository among eight right ones left all eight `unjudged`, because
    /// each of them saw a set of peers that did not agree. The expectation is
    /// the strict majority, so a single dissenter is the only row that changes.
    static func judged(_ readings: [RepositoryIdentity]) -> [RepositoryIdentity] {
        let accounts = expectations(of: readings, keyedBy: \.forge)
        return readings.map { reading in
            reading.with(verdict: verdict(for: reading, accounts: accounts, among: readings))
        }
    }

    /// What each electorate expects, for the electorates that expect anything.
    ///
    /// A tie expects nothing: two names with equal standing is somebody who
    /// commits under both, and naming either of them the right one would
    /// invent the answer this reads rather than guesses.
    static func expectations(
        of readings: [RepositoryIdentity], keyedBy key: KeyPath<RepositoryIdentity, String?>
    ) -> [String: GitForgeExpectation] {
        var tallies: [String: [GitAuthor: Int]] = [:]
        for reading in readings {
            guard let group = reading[keyPath: key], let author = reading.author else { continue }
            tallies[group, default: [:]][author, default: 0] += 1
        }
        return tallies.compactMapValues { tally in
            guard let top = tally.max(by: { $0.value < $1.value }),
                top.value >= minimumAgreement,
                tally.values.count(where: { $0 == top.value }) == 1
            else { return nil }
            return GitForgeExpectation(author: top.key, agreeing: top.value)
        }
    }

    /// What the rest of a host expects, where every account on it but this
    /// one agrees.
    ///
    /// **The repository being judged is not in its own electorate.** Counting
    /// it makes a dissenter the reason its own host is not unanimous, which
    /// acquits exactly the row the fallback exists to catch — measured by the
    /// test that asserts a fresh account is judged at all.
    ///
    /// Unanimity rather than a majority, because this answers for an account
    /// with nothing of its own to compare against, and a host that is merely
    /// mostly one name is the mixed host whose minority must not be called
    /// wrong.
    private static func fallback(
        for reading: RepositoryIdentity, among readings: [RepositoryIdentity]
    ) -> GitForgeExpectation? {
        guard let host = reading.host, let mine = reading.forge else { return nil }
        var agreed: GitAuthor?
        var agreeing = 0
        for other in readings where other.host == host && other.forge != mine {
            guard let theirs = other.author else { continue }
            if let agreed, agreed != theirs { return nil }
            agreed = theirs
            agreeing += 1
        }
        guard let agreed, agreeing >= minimumAgreement else { return nil }
        return GitForgeExpectation(author: agreed, agreeing: agreeing)
    }

    private static func verdict(
        for reading: RepositoryIdentity, accounts: [String: GitForgeExpectation],
        among readings: [RepositoryIdentity]
    ) -> GitIdentityVerdict {
        guard let author = reading.author,
            let wanted = reading.forge.flatMap({ accounts[$0] })
                ?? fallback(for: reading, among: readings)
        else { return .unjudged }
        return author == wanted.author
            ? .agrees
            : .unexpected(expected: wanted.author, agreeing: wanted.agreeing)
    }
}

/// What one electorate's repositories agree on, and how many of them do.
struct GitForgeExpectation: Sendable, Equatable {
    let author: GitAuthor
    let agreeing: Int
}
