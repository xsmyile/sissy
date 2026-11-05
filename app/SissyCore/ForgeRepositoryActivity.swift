import Foundation

/// A repository as a forge names it: the host and the whole path, nested
/// groups included, lowercased because neither forge minds the case and a
/// clone's remote keeps whatever was typed.
struct ForgeRepositoryID: Sendable, Hashable {
    let host: String
    let fullName: String

    init(host: String, fullName: String) {
        self.host = host.lowercased()
        self.fullName = fullName.lowercased()
    }
}

/// What the account did in one repository over a window. Nil is a counter that
/// was switched off or would not read, which is never the same as a zero.
struct ForgeRepositoryCounts: Sendable, Equatable {
    var merged: Int?
    var issues: Int?
    var comments: Int?

    /// Every figure summed, which is only good for telling which of two
    /// instances on one host actually has the repository.
    var total: Int { (merged ?? 0) + (issues ?? 0) + (comments ?? 0) }
}

/// What the projects page asks a forge about: which repositories, over which
/// local days, as of when.
struct ForgeRepositoryQuery: Sendable {
    let repositories: Set<ForgeRepositoryID>
    let from: Date
    let to: Date
    let now: Date
}

/// One connection's answer for the repositories on its host. Empty where the
/// connection would not answer, which draws no counters rather than zeros.
struct ForgeRepositoryReading: Sendable, Equatable {
    let kind: ForgeKind
    let host: String
    var counts: [ForgeRepositoryID: ForgeRepositoryCounts]
}

/// The same three figures `ForgeSpanFeed` reads per account, split by
/// repository, for the rows of the projects page.
///
/// **Read when that page opens and never by the poll**, because a window's
/// worth of repositories is not a number anybody looks at unless the list is on
/// screen. The rule `ForgeActivityFeed` states against a request per repository
/// still holds: measured 2026-11-05, GitHub answers four repositories' merged
/// and opened counts and the comment page in one document costing 1 point, and
/// GitLab answers every repository from three account-wide reads that are split
/// here, 64 merges, 19 issues and 18 comments across five projects.
///
/// **No contributions.** GitHub's split of contributions by repository names public
/// repositories only: measured the same day, it named one repository while a
/// private one with 174 merged pull requests was absent and 497 contributions
/// stayed anonymous. Commits on the default branch were 175 against those 174,
/// the same work counted twice under squash merges.
///
/// **A window GitHub's comment page cannot prove has no comment figure on any
/// row**, the rule `ForgeSpanFeed.commentCount` holds for the account. On a busy
/// account that page reaches about a week back, so a wider window shows merges
/// and issues alone.
enum ForgeRepositoryFeed {
    /// How many repositories one GitHub document asks about, which bounds the
    /// document on a window that names every repository the archive holds.
    static let gitHubBatch = 25
    /// How far a GitLab listing is followed. Past it the counter is absent: a
    /// partial count would read as an exact one.
    static let gitLabPageLimit = 10
    static let gitLabPageSize = 100
    /// How many projects a window's comments may name that no merge request or
    /// issue already did, each of which costs a lookup.
    static let gitLabLookupLimit = 20

    private static let mergeRequestsPath = "/api/v4/merge_requests"
    private static let issuesPath = "/api/v4/issues"
    private static let eventsPath = "/api/v4/events"
    private static let projectsPath = "/api/v4/projects"
    private static let ownScope = "created_by_me"
    private static let referenceSeparators: Set<Character> = ["!", "#"]

    static func read(
        _ connection: ForgeConnection, token: String, counters enabled: Set<ForgeCounter>,
        query: ForgeRepositoryQuery
    ) async throws -> [ForgeRepositoryID: ForgeRepositoryCounts] {
        guard let bounds = ForgeSpanFeed.bounds(from: query.from, to: query.to, now: query.now)
        else { return [:] }
        let asked = Dictionary(
            query.repositories.map { (onForge($0, basePath: connection.basePath), $0) },
            uniquingKeysWith: { first, _ in first })
        let names = Set(asked.keys)
        let counts =
            switch connection.kind {
            case .gitHub:
                try await readGitHub(
                    connection, token: token, counters: enabled, repositories: names, bounds: bounds)
            case .gitLab:
                try await readGitLab(
                    connection, token: token, counters: enabled, repositories: names, bounds: bounds)
            }
        return Dictionary(
            counts.compactMap { name, figures in asked[name].map { ($0, figures) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// A repository as its forge's API names it. A remote on an instance served
    /// under a path carries that path, `gitlab/group/proj`, and the API answers
    /// `group/proj`, so without this every row on such an instance goes blank.
    static func onForge(_ repository: ForgeRepositoryID, basePath: String?) -> ForgeRepositoryID {
        guard let basePath else { return repository }
        let prefix = basePath.drop { $0 == "/" }.lowercased() + "/"
        guard repository.fullName.hasPrefix(prefix) else { return repository }
        return ForgeRepositoryID(
            host: repository.host, fullName: String(repository.fullName.dropFirst(prefix.count)))
    }

    // MARK: GitHub

    private static func readGitHub(
        _ connection: ForgeConnection, token: String, counters enabled: Set<ForgeCounter>,
        repositories: Set<ForgeRepositoryID>, bounds: ForgeSpanFeed.VendorBounds
    ) async throws -> [ForgeRepositoryID: ForgeRepositoryCounts] {
        guard let endpoint = GitHubActivityFeed.endpoint(connection) else {
            throw ForgeReadFailure.malformed
        }
        let ordered = repositories.sorted { $0.fullName < $1.fullName }
        var result = Dictionary(uniqueKeysWithValues: ordered.map { ($0, ForgeRepositoryCounts()) })
        let perRepository = enabled.contains(.merged) || enabled.contains(.issues)
        guard perRepository || enabled.contains(.comments) else { return result }
        let batches =
            perRepository
            ? stride(from: 0, to: ordered.count, by: gitHubBatch).map {
                Array(ordered[$0..<min($0 + gitHubBatch, ordered.count)])
            } : [[]]
        var comments: Tally?
        for (position, batch) in batches.enumerated() {
            let readsComments = position == 0 && enabled.contains(.comments)
            let document = gitHubDocument(
                repositories: batch, bounds: bounds, counters: enabled, comments: readsComments)
            let reply: (data: [String: Any], failures: [String: ForgeSpanAbsence])
            do {
                reply = try await ForgeSpanFeed.graphQL(
                    endpoint, query: document.query, variables: document.variables, token: token,
                    kind: .gitHub)
            } catch {
                try Task.checkCancellation()
                sissyLog("sissy: \(connection.id) repository counters stopped at batch \(position): \(error)")
                break
            }
            for (index, repository) in batch.enumerated() {
                result[repository]?.merged = figure(
                    reply, alias: "m\(index)", wanted: enabled.contains(.merged))
                result[repository]?.issues = figure(
                    reply, alias: "i\(index)", wanted: enabled.contains(.issues))
            }
            if readsComments {
                comments = gitHubComments(
                    reply.data["viewer"] as? [String: Any] ?? [:], bounds: bounds)
            }
        }
        if let comments {
            for repository in ordered {
                result[repository]?.comments = comments.counts[repository.fullName] ?? 0
            }
        }
        return result
    }

    /// The document for one batch. Every repository name travels as a variable:
    /// it comes out of a `.git/config`, and a document is no place for text
    /// that was not written here.
    static func gitHubDocument(
        repositories: [ForgeRepositoryID], bounds: ForgeSpanFeed.VendorBounds,
        counters enabled: Set<ForgeCounter>, comments: Bool
    ) -> (query: String, variables: [String: String]) {
        let dates = "\(ForgeWindow.instant(bounds.start))..\(ForgeWindow.instant(bounds.lastInstant))"
        var variables: [String: String] = [:]
        var fields: [String] = []
        for (index, repository) in repositories.enumerated() {
            for (alias, wanted, terms) in [
                ("m\(index)", enabled.contains(.merged), "is:pr author:@me is:merged merged:\(dates)"),
                ("i\(index)", enabled.contains(.issues), "is:issue author:@me created:\(dates)"),
            ] where wanted {
                variables[alias] = "repo:\(repository.fullName) \(terms)"
                fields.append("\(alias): search(query: $\(alias), type: ISSUE, first: 1) { issueCount }")
            }
        }
        if comments {
            fields.append(
                "viewer { comments: issueComments(first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) "
                    + "{ pageInfo { hasNextPage } nodes { createdAt updatedAt repository { nameWithOwner } } } }"
            )
        }
        let declared = variables.keys.sorted().map { "$\($0): String!" }.joined(separator: ", ")
        let head = declared.isEmpty ? "query" : "query(\(declared))"
        let body = fields.isEmpty ? "viewer { login }" : fields.joined(separator: " ")
        return ("\(head) { \(body) }", variables)
    }

    private static func figure(
        _ reply: (data: [String: Any], failures: [String: ForgeSpanAbsence]), alias: String, wanted: Bool
    ) -> Int? {
        guard wanted else { return nil }
        guard
            case .counted(.exact(let value)) = ForgeSpanFeed.count(
                reply.data, alias: alias, failures: reply.failures, field: "issueCount")
        else { return nil }
        return value
    }

    /// The window's comments by repository, nil where the page cannot prove it
    /// holds all of them.
    static func gitHubComments(
        _ viewer: [String: Any], bounds: ForgeSpanFeed.VendorBounds
    ) -> Tally? {
        guard
            case .success(let nodes) = ForgeSpanFeed.provenComments(
                viewer, start: bounds.start, end: bounds.end, inclusiveEnd: bounds.isOpen)
        else { return nil }
        var tally = Tally()
        for node in nodes {
            guard let repository = node["repository"] as? [String: Any],
                let name = repository["nameWithOwner"] as? String
            else { return nil }
            tally.counts[name.lowercased(), default: 0] += 1
        }
        return tally
    }

    // MARK: GitLab

    private static func readGitLab(
        _ connection: ForgeConnection, token: String, counters enabled: Set<ForgeCounter>,
        repositories: Set<ForgeRepositoryID>, bounds: ForgeSpanFeed.VendorBounds
    ) async throws -> [ForgeRepositoryID: ForgeRepositoryCounts] {
        async let merged =
            enabled.contains(.merged)
            ? listing(
                connection, token: token, path: mergeRequestsPath,
                query: [
                    ("scope", ownScope), ("state", "merged"),
                    ("merged_after", ForgeWindow.instant(bounds.start)),
                ], tally: { tallyReferences($0, stamp: "merged_at", bounds: bounds) }) : nil
        async let issues =
            enabled.contains(.issues)
            ? listing(
                connection, token: token, path: issuesPath,
                query: [
                    ("scope", ownScope), ("created_after", ForgeWindow.instant(bounds.start)),
                ], tally: { tallyReferences($0, stamp: "created_at", bounds: bounds) }) : nil
        let (mergedTally, issuesTally) = await (merged, issues)
        try Task.checkCancellation()
        var names: [Int: String] = [:]
        for tally in [mergedTally, issuesTally] {
            names.merge(tally?.projects ?? [:]) { first, _ in first }
        }
        let comments =
            enabled.contains(.comments)
            ? await gitLabComments(connection, token: token, bounds: bounds, names: names) : nil
        try Task.checkCancellation()
        var result: [ForgeRepositoryID: ForgeRepositoryCounts] = [:]
        for repository in repositories {
            result[repository] = ForgeRepositoryCounts(
                merged: mergedTally.map { $0.counts[repository.fullName] ?? 0 },
                issues: issuesTally.map { $0.counts[repository.fullName] ?? 0 },
                comments: comments.map { $0.counts[repository.fullName] ?? 0 })
        }
        return result
    }

    /// One listing's rows, counted, or nil where it would not read or ran past
    /// `gitLabPageLimit`. The failure is logged and the send has already filed
    /// any refusal, so the row loses one counter rather than the whole reading.
    private static func listing(
        _ connection: ForgeConnection, token: String, path: String, query: [(String, String)],
        tally: ([[String: Any]]) -> Tally?
    ) async -> Tally? {
        do {
            return tally(try await gitLabRows(connection, token: token, path: path, query: query))
        } catch {
            if !Task.isCancelled { sissyLog("sissy: GitLab \(path) unreadable: \(error)") }
            return nil
        }
    }

    private static func gitLabRows(
        _ connection: ForgeConnection, token: String, path: String, query: [(String, String)]
    ) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for page in 1...gitLabPageLimit {
            guard let root = connection.root,
                var components = URLComponents(
                    url: root.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            else { throw ForgeReadFailure.malformed }
            components.queryItems =
                query.map { URLQueryItem(name: $0.0, value: $0.1) } + [
                    URLQueryItem(name: "per_page", value: String(gitLabPageSize)),
                    URLQueryItem(name: "page", value: String(page)),
                ]
            guard let url = components.url else { throw ForgeReadFailure.malformed }
            let request = ForgeActivityFeed.request(
                url, token: token, header: GitLabActivityFeed.tokenHeader, scheme: nil)
            let (body, response) = try await ForgeActivityFeed.send(request, token: token)
            guard let batch = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
                throw ForgeReadFailure.malformed
            }
            rows += batch
            if GitLabActivityFeed.isLastPage(response) { return rows }
        }
        throw ForgeSpanAbsence.incomplete
    }

    /// Counts by repository, and on GitLab the project ids the rows taught.
    struct Tally: Equatable {
        var counts: [String: Int] = [:]
        var projects: [Int: String] = [:]
    }

    /// Merge requests or issues inside the window, by the path each one's
    /// reference starts with. The window's end is tested here rather than asked
    /// for, because `merged_before` widens to the end of its UTC day (see
    /// `ForgeSpanFeed.bounds`). A row that will not parse makes the whole count
    /// absent: dropping it would report a short count as an exact one.
    static func tallyReferences(
        _ rows: [[String: Any]], stamp key: String, bounds: ForgeSpanFeed.VendorBounds
    ) -> Tally? {
        var tally = Tally()
        for row in rows {
            guard let stamp = (row[key] as? String).flatMap(UsageReaderShared.parseTimestamp),
                let references = row["references"] as? [String: Any],
                let reference = references["full"] as? String,
                let separator = reference.firstIndex(where: referenceSeparators.contains),
                let project = row["project_id"] as? Int
            else { return nil }
            let name = reference[..<separator].lowercased()
            tally.projects[project] = name
            if inWindow(stamp, bounds) { tally.counts[name, default: 0] += 1 }
        }
        return tally
    }

    private static func inWindow(_ stamp: Date, _ bounds: ForgeSpanFeed.VendorBounds) -> Bool {
        stamp >= bounds.start && (bounds.isOpen ? stamp <= bounds.end : stamp < bounds.end)
    }

    /// The account's comments by repository. An event names a project only by
    /// id, so one no merge request or issue explained is looked up: leaving it
    /// out would draw a comment count short on exactly the repository where
    /// the account only talked.
    private static func gitLabComments(
        _ connection: ForgeConnection, token: String, bounds: ForgeSpanFeed.VendorBounds,
        names known: [Int: String]
    ) async -> Tally? {
        do {
            let rows = try await gitLabRows(
                connection, token: token, path: eventsPath,
                query: [
                    ("action", GitLabActivityFeed.commentedAction),
                    ("after", GitLabDaySplit.name(bounds.start, days: -1)),
                    ("before", GitLabDaySplit.name(bounds.lastInstant, days: 1)),
                ])
            let perProject = try tallyEvents(rows, bounds: bounds)
            let unknown = perProject.keys.filter { known[$0] == nil }
            guard unknown.count <= gitLabLookupLimit else { return nil }
            var names = known
            for project in unknown {
                names[project] = try await projectPath(project, connection: connection, token: token)
            }
            var tally = Tally()
            for (project, count) in perProject {
                if let name = names[project] { tally.counts[name, default: 0] += count }
            }
            return tally
        } catch {
            if !Task.isCancelled { sissyLog("sissy: GitLab comments unreadable: \(error)") }
            return nil
        }
    }

    /// The window's events by project id, throwing where a row will not parse:
    /// dropping it would report a short count as an exact one. A comment on a
    /// group's epic or a personal snippet has no project, so it is in no
    /// repository's count and not a reason to lose all of them.
    static func tallyEvents(
        _ rows: [[String: Any]], bounds: ForgeSpanFeed.VendorBounds
    ) throws -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for row in rows {
            guard let stamp = (row["created_at"] as? String).flatMap(UsageReaderShared.parseTimestamp)
            else { throw ForgeReadFailure.malformed }
            guard let project = row["project_id"] as? Int else { continue }
            if inWindow(stamp, bounds) { counts[project, default: 0] += 1 }
        }
        return counts
    }

    /// A project's path, nil for one this token may no longer read. That is an
    /// answer rather than a failure: a moved or deleted project is not any row
    /// on the page, and a `403` sent without `answeringRefusals` would file the
    /// whole connection's token as refused.
    private static func projectPath(
        _ project: Int, connection: ForgeConnection, token: String
    ) async throws -> String? {
        guard let url = connection.root?.appendingPathComponent("\(projectsPath)/\(project)") else {
            throw ForgeReadFailure.malformed
        }
        let request = ForgeActivityFeed.request(
            url, token: token, header: GitLabActivityFeed.tokenHeader, scheme: nil)
        let (body, response) = try await ForgeActivityFeed.send(
            request, token: token, answeringRefusals: true)
        guard response.statusCode != 404, response.statusCode != 403 else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let path = object["path_with_namespace"] as? String
        else { throw ForgeReadFailure.malformed }
        return path.lowercased()
    }
}
