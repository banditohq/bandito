import BanditoKit
import Foundation

/// One tile of the Marketplace: a service from the catalog, or an integration the owner added by hand.
struct MarketEntry: Identifiable, Equatable {
    /// `catalog:<template id>` or `own:<integration id>`. Unique in one list.
    let id: String
    let name: String
    /// The catalog description in the app's language, or the address of an own integration.
    let description: String
    /// The catalog template; `nil` for an own integration.
    let template: IntegrationCatalogEntry?
    /// The integration on the server with this name; `nil` when the service is not connected.
    let integration: Integration?

    var isConnected: Bool { integration != nil }

    /// The category of the catalog template; nil for an own integration.
    var category: String? { template?.category }
}

/// The page of the Marketplace for one filter and one search: the connected row above the grid, and the grid.
struct MarketPage: Equatable {
    /// Shown above the grid under the All filter, only when some connected service matches the search.
    var connected: [MarketEntry]
    /// The catalog entries the filter and the search keep, in the order of `MarketLogic.entries`. Under the All filter
    /// the connected ones are not here: they are in `connected`.
    var grid: [MarketEntry]
}

/// One step of "How to connect" on the page of a service.
enum MarketStep: Equatable {
    /// Get the key or token (the documentation says where).
    case getKey
    /// Put your own parts into the address (a project, a server id).
    case fillAddress
    /// Put your own folder or repository path into the command.
    case fillPath
    /// Press Connect, paste the key, check.
    case connect
}

/// Why the page has nothing to show.
enum MarketEmptyState: Equatable {
    /// A search matched nothing.
    case noResults
    /// The Connected filter with nothing connected.
    case nothingConnected
}

/// The rules of the Marketplace list. Pure, so the filter, the search and the order are easy to test.
enum MarketLogic {
    /// The catalog templates in catalog order, then the own integrations that no template matches, in their order.
    /// A template whose name is taken by an integration is connected: it is one entry, not two.
    static func entries(
        catalog: [IntegrationCatalogEntry], integrations: [Integration], languageCode: String
    ) -> [MarketEntry] {
        let templates = catalog.map { template in
            MarketEntry(
                id: "catalog:\(template.id)",
                name: template.name,
                description: template.description(languageCode: languageCode),
                template: template,
                integration: integrations.first { $0.name == template.id })
        }
        let templateIDs = Set(catalog.map(\.id))
        let own = integrations.filter { !templateIDs.contains($0.name) }.map { integration in
            MarketEntry(
                id: "own:\(integration.id)",
                name: integration.name,
                description: address(integration),
                template: nil,
                integration: integration)
        }
        return templates + own
    }

    /// The entries the filter keeps, then the ones the search keeps. The search reads the name and the description,
    /// ignores case, and ignores spaces at the ends. An empty search keeps everything.
    static func visible(_ entries: [MarketEntry], filter: MarketFilter, query: String) -> [MarketEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch filter {
            case .all: true
            case .connected: entry.isConnected
            case .category(let name): entry.category == name
            }
        }.filter { entry in
            needle.isEmpty
                || entry.name.localizedCaseInsensitiveContains(needle)
                || entry.description.localizedCaseInsensitiveContains(needle)
        }
    }

    /// The page for a filter and a search. Under the All filter the connected services form the row above, and the
    /// grid keeps the rest of the catalog. The Connected filter has the grid alone, with the connected services.
    static func page(_ entries: [MarketEntry], filter: MarketFilter, query: String) -> MarketPage {
        let connected = visible(entries, filter: .connected, query: query)
        switch filter {
        case .all:
            return MarketPage(
                connected: connected,
                grid: visible(entries, filter: .all, query: query).filter { !$0.isConnected })
        case .connected:
            return MarketPage(connected: [], grid: connected)
        case .category:
            // A category lists its services whether or not they are connected.
            return MarketPage(connected: [], grid: visible(entries, filter: filter, query: query))
        }
    }

    /// The entry whose page is open, or nil when it is gone (removed, or the catalog reloaded without it).
    static func entry(withID id: String?, in entries: [MarketEntry]) -> MarketEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    /// The steps of "How to connect" for a catalog entry, from its fields. Pure data, so the view only translates it.
    static func steps(for template: IntegrationCatalogEntry) -> [MarketStep] {
        var steps: [MarketStep] = []
        let keys = template.kind == .http ? template.headersKeys : template.envKeys
        if keys.contains(where: \.secret) { steps.append(.getKey) }
        if template.kind == .http, template.url == nil { steps.append(.fillAddress) }
        if template.kind == .stdio, template.args.contains(where: { $0.hasPrefix("/path/") }) { steps.append(.fillPath) }
        steps.append(.connect)
        return steps
    }

    /// What to say when the page is empty: a search with no match, or the Connected filter with nothing connected.
    /// `nil` when there is something to show, or when the All filter has every service connected (the row shows them).
    static func emptyState(_ page: MarketPage, filter: MarketFilter, query: String) -> MarketEmptyState? {
        guard page.grid.isEmpty && page.connected.isEmpty else { return nil }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noResults }
        return filter == .connected ? .nothingConnected : nil
    }

    /// The address of an own integration: `https://…` for a web one, the command and its arguments for a program.
    static func address(_ integration: Integration) -> String {
        switch integration.kind {
        case .http:
            return integration.url ?? ""
        case .stdio:
            return ([integration.command ?? ""] + integration.args).joined(separator: " ")
        }
    }
}
