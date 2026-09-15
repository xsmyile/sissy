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

    /// Whether this level is worth interrupting a glance for. `unknown` is
    /// not: it says Sissy has no reading, which is not news about the vendor.
    var isDegraded: Bool {
        switch self {
        case .operational, .unknown: return false
        case .maintenance, .minor, .major, .critical: return true
        }
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
enum ProviderStatusFeed {
    private static let roots: [String: String] = [
        ProviderID.claudeCode: "https://status.claude.com",
        ProviderID.codex: "https://status.openai.com",
    ]

    static func root(for provider: String) -> URL? {
        roots[provider].flatMap(URL.init(string:))
    }
}
