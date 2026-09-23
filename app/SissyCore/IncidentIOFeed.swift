import Foundation

/// The second component shape, and the only reason there is more than one
/// reader here.
///
/// OpenAI's page runs on incident.io, which emulates Statuspage well enough
/// for the sentence and not for the services. Measured 2026-09-15: its
/// `api/v2/summary.json` answered 25 flat components where this feed answers
/// 34 in 5 groups — the emulation drops eight of them, `CLI` among them, and
/// folds the two `Login` components into one. So the tree is read here.
///
/// The document says which components are *affected* and lists the rest only
/// in its structure, so anything absent from `affected_components` is
/// operational. On the day this was measured that list was empty and every one
/// of the 34 read as operational, which is the shape this parser was written
/// against.
enum IncidentIOFeed {
    static func componentsURL(root: URL) -> URL? {
        guard let host = root.host() else { return nil }
        return URL(string: "https://\(host)/proxy/\(host)")
    }

    static func components(root: URL) async throws -> [ProviderStatusComponent] {
        guard let url = componentsURL(root: root) else {
            throw ProviderStatusError.malformedPayload
        }
        var request = URLRequest(url: url, timeoutInterval: StatuspageFeed.requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await SissyHTTP.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderStatusError.malformedPayload
        }
        guard http.statusCode == 200 else {
            throw ProviderStatusError.badStatus(http.statusCode)
        }
        return try parse(data)
    }

    /// The page's own structure, with each component's status looked up in the
    /// affected list and defaulted to operational.
    ///
    /// A hidden row is dropped for the reason Statuspage's
    /// `only_show_if_degraded` rows are: the tree is a copy of a page, and a
    /// row that page does not draw is one the user would not find by opening
    /// it either.
    static func parse(_ data: Data) throws -> [ProviderStatusComponent] {
        let payload = try JSONDecoder().decode(IncidentIOPayload.self, from: data)
        let affected = Dictionary(
            payload.summary.affectedComponents.map { ($0.componentID, $0.status) },
            uniquingKeysWith: { first, _ in first })
        return payload.summary.structure.items.compactMap { item in
            if let group = item.group {
                guard !group.hidden else { return nil }
                let children = group.components
                    .filter { !$0.hidden }
                    .map { leaf(id: $0.componentID, name: $0.name, affected: affected) }
                guard !children.isEmpty else { return nil }
                return .group(id: group.id, name: group.name, children: children)
            }
            guard let component = item.component, !component.hidden else { return nil }
            return leaf(id: component.componentID, name: component.name, affected: affected)
        }
    }

    private static func leaf(id: String, name: String, affected: [String: String])
        -> ProviderStatusComponent
    {
        let status = affected[id] ?? "operational"
        return ProviderStatusComponent(
            id: id, name: name, indicator: ProviderStatusIndicator(component: status),
            status: status)
    }
}

/// incident.io's page summary, cut down to the two things a tree needs: which
/// components exist and which of them are in trouble.
///
/// Flat rather than nested to a shape that mirrors the document, because the
/// document is nested four deep and reading it back is not what these types
/// are for.
private struct IncidentIOPayload: Decodable {
    let summary: IncidentIOSummary
}

private struct IncidentIOSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case affectedComponents = "affected_components"
        case structure
    }

    let affectedComponents: [IncidentIOAffected]
    let structure: IncidentIOStructure

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        affectedComponents =
            try container.decodeIfPresent([IncidentIOAffected].self, forKey: .affectedComponents)
            ?? []
        structure =
            try container.decodeIfPresent(IncidentIOStructure.self, forKey: .structure)
            ?? IncidentIOStructure(items: [])
    }
}

private struct IncidentIOAffected: Decodable {
    private enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case status
    }

    let componentID: String
    let status: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        componentID = try container.decode(String.self, forKey: .componentID)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "operational"
    }
}

/// The page's own layout: a flat list of items, each of which is one component
/// or a group of them.
private struct IncidentIOStructure: Decodable {
    private enum CodingKeys: String, CodingKey {
        case items
    }

    let items: [IncidentIOItem]

    init(items: [IncidentIOItem]) { self.items = items }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([IncidentIOItem].self, forKey: .items) ?? []
    }
}

private struct IncidentIOItem: Decodable {
    let group: IncidentIOGroup?
    let component: IncidentIOComponent?
}

private struct IncidentIOGroup: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, hidden, components
    }

    let id: String
    let name: String
    let hidden: Bool
    let components: [IncidentIOComponent]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        components =
            try container.decodeIfPresent([IncidentIOComponent].self, forKey: .components) ?? []
    }
}

private struct IncidentIOComponent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case name, hidden
    }

    let componentID: String
    let name: String
    let hidden: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        componentID = try container.decode(String.self, forKey: .componentID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}
