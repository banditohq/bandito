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
}

/// The page of the Marketplace for one filter and one search: the connected row above the grid, and the grid.
struct MarketPage: Equatable {
    /// Shown above the grid under the All filter, only when some connected service matches the search.
    var connected: [MarketEntry]
    /// Every entry the filter and the search keep, in the order of `MarketLogic.entries`.
    var grid: [MarketEntry]
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
            guard filter == .connected else { return true }
            return entry.isConnected
        }.filter { entry in
            needle.isEmpty
                || entry.name.localizedCaseInsensitiveContains(needle)
                || entry.description.localizedCaseInsensitiveContains(needle)
        }
    }

    /// The page for a filter and a search. The connected row shows only under the All filter, so the Connected filter
    /// has the grid alone.
    static func page(_ entries: [MarketEntry], filter: MarketFilter, query: String) -> MarketPage {
        MarketPage(
            connected: filter == .all ? visible(entries, filter: .connected, query: query) : [],
            grid: visible(entries, filter: filter, query: query))
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
