import BanditoDesign
import BanditoL10n
import Foundation
import SwiftUI

/// Helpers for the main agent of a server. Which agent it is comes from the daemon (`Agent.lead`).
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
