import BanditoDesign
import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// The main agent of each server: the one that answers for the others. The daemon has no field for it yet, so the
/// choice is kept on this Mac, one main agent per server. Making another agent main replaces the old choice.
@MainActor
@Observable
final class LeadAgentStore {
    static let shared = LeadAgentStore()

    static let defaultsKey = "bandito.leadAgents"

    /// Server id → main agent id. Views that read it are drawn again when it changes.
    private(set) var leads: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        leads = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// The main agent's id on this server, or `nil` when none is set.
    func id(server: String) -> String? {
        leads[server]
    }

    /// Sets the main agent of this server, or clears it with `nil`.
    func set(_ agentID: String?, server: String) {
        leads[server] = agentID
        defaults.set(leads, forKey: Self.defaultsKey)
    }

    /// Clears the choice when the main agent is deleted. Another agent's choice is left as it is.
    func forget(agentID: String, server: String) {
        guard leads[server] == agentID else { return }
        set(nil, server: server)
    }
}

enum LeadAgent {
    /// The main item first; the rest keep their order. A main id that is no longer in the list changes nothing.
    static func leadFirst<Item>(_ items: [Item], id: (Item) -> String, lead: String?) -> [Item] {
        guard let lead, let index = items.firstIndex(where: { id($0) == lead }), index > 0 else { return items }
        var out = items
        let item = out.remove(at: index)
        out.insert(item, at: 0)
        return out
    }
}

/// The crown on the avatar of the main agent, in the team list and in the thread header.
struct LeadCrown: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: size * 0.6, weight: .bold))
            .foregroundStyle(BanditoPalette.peach)
            .frame(width: size, height: size)
            .background(Color.Bandito.surface1, in: Circle())
            .help(L10n.Team.leadHelp)
            .accessibilityLabel(L10n.Team.leadHelp)
    }
}
