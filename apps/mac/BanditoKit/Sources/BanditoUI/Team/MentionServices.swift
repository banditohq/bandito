import BanditoKit
import Foundation
import Observation

/// The catalog and the connected services of each server, kept for the `@` menu and for the chips in the thread (a
/// chip of a service wears the logo the Marketplace shows). Read on demand and not more than once a minute.
@MainActor
@Observable
final class MentionServices {
    static let shared = MentionServices()

    struct Snapshot: Equatable {
        var catalog: [IntegrationCatalogEntry]
        var integrations: [Integration]
    }

    /// How long a reading is trusted unless the menu asks for a new one.
    static let freshFor: TimeInterval = 60

    private(set) var snapshots: [UUID: Snapshot] = [:]
    @ObservationIgnored private var readAt: [UUID: Date] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []

    func snapshot(for server: ServerModel) -> Snapshot? {
        snapshots[server.id]
    }

    /// Reads the integrations and, once, the catalog. A failed read keeps what was known. A daemon without
    /// `integrations` has nothing to read.
    func ensure(_ server: ServerModel, force: Bool = false) async {
        guard server.supports("integrations"), !loading.contains(server.id) else { return }
        if !force, let at = readAt[server.id], Date().timeIntervalSince(at) < Self.freshFor { return }
        loading.insert(server.id)
        defer { loading.remove(server.id) }
        let known = snapshots[server.id]
        guard let integrations = try? await server.integrations() else { return }
        var catalog = known?.catalog ?? []
        if catalog.isEmpty, let fetched = try? await server.integrationCatalog() { catalog = fetched }
        let next = Snapshot(catalog: catalog, integrations: integrations)
        if next != known { snapshots[server.id] = next }
        readAt[server.id] = Date()
    }

    /// The Marketplace entry a service mention stands for: the one whose integration has the mention's id, else the
    /// one the label names (a service connected since, or removed since).
    nonisolated static func market(
        for mention: Mention, catalog: [IntegrationCatalogEntry], integrations: [Integration], languageCode: String
    ) -> MarketEntry? {
        guard mention.kind == .integration else { return nil }
        let entries = MarketLogic.entries(catalog: catalog, integrations: integrations, languageCode: languageCode)
        if let byID = entries.first(where: { $0.integration?.id == mention.id }) { return byID }
        let label = SearchFolding.fold(mention.label)
        return entries.first { SearchFolding.fold($0.name) == label && !$0.isOwn }
    }
}
