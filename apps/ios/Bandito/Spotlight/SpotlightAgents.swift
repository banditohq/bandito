import BanditoKit
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// Spotlight finds the agents by name and role (domain "agents"). The index follows the directory the widgets' snapshot
// holds: a change adds, updates or removes only the items that differ, and a server taken off the phone drops its
// agents. A tap on a result is the agent's link (`bandito://agent/...`), read by `SpotlightAgents.link(from:)`.

enum SpotlightAgents {
    static let domain = "agents"

    /// An agent's item: the title is its name, the description its role, the id "<server>/<agent>".
    static func item(for listing: WidgetSnapshot.Listing) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = listing.name
        attributes.contentDescription = listing.role.isEmpty ? nil : listing.role
        attributes.keywords = ["Bandito", listing.name] + (listing.role.isEmpty ? [] : [listing.role])
        return CSSearchableItem(uniqueIdentifier: identifier(for: listing), domainIdentifier: domain, attributeSet: attributes)
    }

    /// The id of an agent's item, which is also its link's path.
    static func identifier(for listing: WidgetSnapshot.Listing) -> String {
        "\(listing.server)/\(listing.id)"
    }

    /// What the index holds for an item: its name and role. A change of either is an update.
    static func signature(of listing: WidgetSnapshot.Listing) -> String {
        "\(listing.name)\u{1F}\(listing.role)"
    }

    /// The change from the indexed items (id → signature) to the directory: the items to (re)index and the ids to delete.
    struct Plan: Equatable {
        var update: [WidgetSnapshot.Listing]
        var remove: [String]

        var isEmpty: Bool { update.isEmpty && remove.isEmpty }
    }

    static func plan(indexed: [String: String], directory: [WidgetSnapshot.Listing]) -> Plan {
        var update: [WidgetSnapshot.Listing] = []
        var seen: Set<String> = []
        for listing in directory {
            let id = identifier(for: listing)
            guard seen.insert(id).inserted else { continue }
            if indexed[id] != signature(of: listing) { update.append(listing) }
        }
        let remove = indexed.keys.filter { !seen.contains($0) }.sorted()
        return Plan(update: update, remove: remove)
    }

    /// The link a Spotlight item opens: its id is "<server>/<agent>". Nil for any other id.
    static func link(forIdentifier identifier: String) -> BanditoLink? {
        guard let slash = identifier.firstIndex(of: "/") else { return nil }
        let server = String(identifier[..<slash])
        let agent = String(identifier[identifier.index(after: slash)...])
        guard !server.isEmpty, !agent.isEmpty, !agent.contains("/") else { return nil }
        return .agent(server: server, id: agent)
    }

    /// The link of a tap on a Spotlight result, nil for any other activity.
    static func link(from activity: NSUserActivity) -> BanditoLink? {
        guard activity.activityType == CSSearchableItemActionType,
            let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        return link(forIdentifier: identifier)
    }
}

/// The Spotlight index of the agents. Keeps what it indexed (id → signature) in UserDefaults, so a launch indexes only
/// what changed since the last one.
@MainActor
final class SpotlightAgentIndex {
    static let shared = SpotlightAgentIndex(index: .default(), defaults: .standard)
    static let defaultsKey = "ios.spotlight.agents"

    private let index: CSSearchableIndex
    private let defaults: UserDefaults
    private var indexed: [String: String]

    init(index: CSSearchableIndex, defaults: UserDefaults) {
        self.index = index
        self.defaults = defaults
        indexed = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// Brings the index to the directory: only the agents that are new or changed are indexed, the ones gone are deleted.
    func sync(_ directory: [WidgetSnapshot.Listing]) {
        apply(SpotlightAgents.plan(indexed: indexed, directory: directory))
    }

    /// Deletes the agents of the servers that are no longer paired.
    func keepOnly(serverIDs: Set<String>) {
        let gone = indexed.keys.filter { id in
            guard let slash = id.firstIndex(of: "/") else { return true }
            return !serverIDs.contains(String(id[..<slash]))
        }
        guard !gone.isEmpty else { return }
        apply(SpotlightAgents.Plan(update: [], remove: gone.sorted()))
    }

    private func apply(_ plan: SpotlightAgents.Plan) {
        guard !plan.isEmpty else { return }
        if !plan.remove.isEmpty {
            index.deleteSearchableItems(withIdentifiers: plan.remove, completionHandler: nil)
            for id in plan.remove { indexed.removeValue(forKey: id) }
        }
        if !plan.update.isEmpty {
            index.indexSearchableItems(plan.update.map(SpotlightAgents.item(for:)), completionHandler: nil)
            for listing in plan.update { indexed[SpotlightAgents.identifier(for: listing)] = SpotlightAgents.signature(of: listing) }
        }
        defaults.set(indexed, forKey: Self.defaultsKey)
    }
}
