import Foundation

/// Which words an account is called by wherever the panel and Settings name
/// it.
///
/// The organisation leads only for a plan that belongs to one. claude.ai
/// generates the organisation of a personal plan itself — measured 2026-09-16,
/// `<email>'s Organization` and `<name>'s Individual Org` — so naming a Max
/// account after it printed the address twice and a word nobody chose.
enum AccountNameFormat: String, Codable, CaseIterable, Sendable {
    /// The organisation for a team seat, the person for a personal plan.
    case automatic
    /// The address, which is unique by construction.
    case email
    /// The person, with the organisation beside it on a team seat.
    case nameAndOrganization
}

/// How the user wants accounts named: one format for every account, and a name
/// of their own for any account they renamed.
///
/// Keyed by the id the engine files an account under (Anthropic's uuid, the
/// Codex link's key), which survives an address change where a label would
/// not.
struct AccountNaming: Codable, Equatable, Sendable {
    var format: AccountNameFormat = .automatic
    var custom: [String: String] = [:]

    /// The words in a plan token that name a seat in an organisation rather
    /// than a personal subscription. Matched as words of the token rather than
    /// as the whole of it, because OpenAI spells the same plans with
    /// qualifiers: `self_serve_business_usage_based`, `education`.
    static let organizationPlanWords = ["team", "enterprise", "business", "edu"]

    /// What an account is called, nil when nothing the vendor answered names
    /// it, so the caller falls back to whatever key it holds. A nil `id` is an
    /// account no source has filed yet, which cannot carry a rename.
    func name(id: String?, account: ProviderAccount?, plan: String?) -> String? {
        if let id, let renamed = custom[id] { return renamed }
        let organization = Self.organization(of: account, plan: plan)
        let person = account?.name ?? account?.email
        switch format {
        case .automatic:
            return organization ?? person
        case .email:
            return account?.email ?? organization ?? person
        case .nameAndOrganization:
            let parts = [person, organization].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
        }
    }

    /// What the name leaves out: the address and a team seat's organisation,
    /// each only where it is not already one of the name's own parts.
    func detail(name: String, account: ProviderAccount?, plan: String?) -> String? {
        let said = Set(name.components(separatedBy: Self.separator).map { $0.lowercased() })
        let parts = [account?.email, Self.organization(of: account, plan: plan)]
            .compactMap { $0 }
            .filter { !said.contains($0.lowercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    /// A rename, or the account handed back to the format when the field is
    /// left blank.
    mutating func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        custom[id] = trimmed.isEmpty ? nil : trimmed
    }

    private static let separator = " · "

    private static func organization(of account: ProviderAccount?, plan: String?) -> String? {
        guard let plan, isOrganizationPlan(plan) else { return nil }
        return account?.organization
    }

    private static func isOrganizationPlan(_ plan: String) -> Bool {
        let words = plan.lowercased().split { !$0.isLetter }
        return words.contains { word in organizationPlanWords.contains { word.hasPrefix($0) } }
    }
}
