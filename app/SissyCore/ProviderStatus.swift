import Foundation

/// How a vendor describes its own service right now.
///
/// Statuspage's own vocabulary, parsed at the boundary with an `unknown` case
/// rather than a failure: a level a vendor ships after this release reaches
/// the panel as a reading Sissy cannot word, instead of taking the whole reply
/// down with it.
///
/// `operational` rather than `none`, which is the wire's word for it: `none`
/// is the name Swift already gives `Optional`, and the two are
/// indistinguishable at every `case .none` this would be matched in.
enum ProviderStatusIndicator: Sendable, Equatable {
    case operational
    case maintenance
    case minor
    case major
    case critical
    /// A level this build does not know, and the state of a feed that has
    /// never answered. Never an outage: a status page Sissy could not reach is
    /// not an incident, and saying otherwise puts a red row in front of a user
    /// whose wifi dropped.
    case unknown

    /// The page-level `status.indicator`, which is the field both vendors
    /// answer the whole question in.
    ///
    /// Measured 2026-09-15: `status.claude.com/api/v2/status.json` and
    /// `status.openai.com/api/v2/status.json` return the same
    /// `{page, status{indicator, description}}` envelope — the second through
    /// incident.io's emulation of it — so there is one reader here and not
    /// two.
    init(page raw: String) {
        switch raw {
        case "none": self = .operational
        case "maintenance": self = .maintenance
        case "minor": self = .minor
        case "major": self = .major
        case "critical": self = .critical
        default: self = .unknown
        }
    }

    /// A single component's own `status`, which is a second vocabulary on the
    /// same feeds: Statuspage spells it `operational` /
    /// `degraded_performance` / `partial_outage` / `major_outage` /
    /// `under_maintenance`, incident.io adds `full_outage`.
    ///
    /// Only the operational end of this is measured — both pages were healthy
    /// on 2026-09-15, so every component read as `operational` and
    /// incident.io's list of affected ones was empty. The outage tokens are
    /// the two vendors' published sets, and one Sissy does not recognise lands
    /// on `unknown`, which is grey rather than wrong. The row still reads
    /// correctly there, because what it prints is the vendor's own token
    /// worded rather than this case.
    init(component raw: String) {
        switch raw {
        case "operational": self = .operational
        case "under_maintenance": self = .maintenance
        case "degraded_performance": self = .minor
        case "partial_outage": self = .major
        case "major_outage", "full_outage": self = .critical
        default: self = .unknown
        }
    }

    /// Where this level sits against the others, so a group can report the
    /// worst of its children. `unknown` ranks with `operational`: a child
    /// nobody could classify must not outrank a real outage beside it.
    var severity: Int {
        switch self {
        case .operational, .unknown: return 0
        case .maintenance: return 1
        case .minor: return 2
        case .major: return 3
        case .critical: return 4
        }
    }

    /// Whether this level is worth interrupting a glance for. `unknown` is
    /// not: it says Sissy has no reading, which is not news about the vendor.
    var isDegraded: Bool {
        switch self {
        case .operational, .unknown: return false
        case .maintenance, .minor, .major, .critical: return true
        }
    }
}

/// One line of a vendor's status page: a service, or a group of them.
///
/// The raw `status` travels beside the parsed `indicator` for the reason a
/// plan's token does — the app words it, so a value a vendor ships tomorrow
/// still prints as itself instead of as a blank. The indicator is parsed here
/// because the parse is what a group aggregates over.
struct ProviderStatusComponent: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let indicator: ProviderStatusIndicator
    /// The vendor's own status token, unworded.
    let status: String
    /// Empty for a service, populated for a group of them. A flat feed
    /// produces none at all, which is what makes the tree one row deep for
    /// Claude and two for OpenAI without either surface knowing which it has.
    let children: [Self]

    var isGroup: Bool { !children.isEmpty }

    init(
        id: String, name: String, indicator: ProviderStatusIndicator, status: String,
        children: [Self] = []
    ) {
        self.id = id
        self.name = name
        self.indicator = indicator
        self.status = status
        self.children = children
    }

    /// A group reading the worst of what it holds, which is the only honest
    /// summary of a row whose children are collapsed underneath it.
    static func group(
        id: String, name: String, children: [Self]
    ) -> Self {
        let worst =
            children.max { $0.indicator.severity < $1.indicator.severity }
            ?? Self(id: id, name: name, indicator: .operational, status: "operational")
        return Self(
            id: id, name: name, indicator: worst.indicator, status: worst.status,
            children: children)
    }
}

/// What one vendor's status page said, and when Sissy read it.
struct ProviderStatusReading: Sendable, Equatable {
    let indicator: ProviderStatusIndicator
    /// The vendor's own sentence — "All Systems Operational", "Partially
    /// Degraded Service" — shown as given, so wording a vendor changes needs
    /// no release. Nil for a feed that has never answered, which is the one
    /// case the app has to word itself.
    let description: String?
    /// When **Sissy** fetched it, never the feed's own `updated_at`.
    ///
    /// Measured 2026-09-15: OpenAI's `page.updated_at` read `2026-07-09`, two
    /// months stale, because it moves on incidents rather than on polls. A row
    /// sourcing its age from the payload would tell a healthy provider it had
    /// not been heard from since July.
    let checkedAt: Date
    /// The services behind that sentence, in the order the vendor lists them.
    /// Empty for a reply whose component list Sissy could not read, which
    /// leaves the row without a tree rather than with an empty one.
    let components: [ProviderStatusComponent]

    init(
        indicator: ProviderStatusIndicator, description: String?, checkedAt: Date,
        components: [ProviderStatusComponent] = []
    ) {
        self.indicator = indicator
        self.description = description
        self.checkedAt = checkedAt
        self.components = components
    }

    /// The same reading carrying a component list read separately, for the
    /// vendor whose feed splits the sentence and the services across two
    /// documents.
    func with(components: [ProviderStatusComponent]) -> Self {
        Self(
            indicator: indicator, description: description, checkedAt: checkedAt,
            components: components)
    }

    /// The reading a feed that has never answered leaves behind. It carries no
    /// age on purpose: the row words it as unavailable rather than dating a
    /// fetch that produced nothing.
    static func unavailable(at when: Date) -> Self {
        Self(indicator: .unknown, description: nil, checkedAt: when)
    }
}

/// Where a vendor publishes its status.
///
/// A URL per provider rather than a reader per provider: both feeds answer the
/// same shape, so adding a provider is a line here rather than a class. A
/// provider that publishes nothing Sissy can poll answers nil and simply has
/// no status row — which is also what keeps a future provider that only has a
/// page to open from needing a poll it cannot serve.
struct ProviderStatusFeed: Sendable, Equatable {
    /// Which document answers for the component list.
    ///
    /// The page-level sentence is one shape for both vendors; the services
    /// under it are two, and the difference is measured rather than assumed.
    /// On 2026-09-15 OpenAI's Statuspage-emulated `summary.json` answered 25
    /// flat components where its own page shows 34 in 5 groups: it drops eight
    /// — `Chat Completions`, `Responses`, `Conversations`, `GPTs`, `Image
    /// Generation`, `ChatGPT Work`, `Ads Manager` and **`CLI`**, which is the
    /// one a Codex user came to look at — and folds the two `Login`
    /// components into one row. So the emulation is enough for the sentence
    /// and not for the tree, and incident.io's own feed is read for that.
    enum Components: Sendable, Equatable {
        /// Atlassian's `api/v2/summary.json`: the sentence and a flat list of
        /// services in one document, which is one request.
        case statuspage
        /// incident.io's `proxy/<host>`: the groups and their services, with
        /// no sentence, so the status endpoint is read beside it.
        case incidentIO
    }

    let root: URL
    let components: Components

    private static let published: [String: (root: String, components: Components)] = [
        ProviderID.claudeCode: ("https://status.claude.com", .statuspage),
        ProviderID.codex: ("https://status.openai.com", .incidentIO),
    ]

    static func feed(for provider: String) -> Self? {
        guard let entry = published[provider], let root = URL(string: entry.root) else {
            return nil
        }
        return Self(root: root, components: entry.components)
    }

    static func root(for provider: String) -> URL? { feed(for: provider)?.root }
}
