import BanditoKit
import Foundation

/// The panel open over the Marketplace page. The id is the template's or the skill's.
enum MarketPanelState: Equatable {
    case botDetail(String)
    case botCreate(String)
    case skillDetail(String)
    case skillInstall(String)
}

/// A skill the person asked to remove, waiting for the answer to the confirmation.
struct SkillRemoval: Identifiable {
    let skill: SkillEntry
    let target: SkillLogic.Target
    /// The agent's name, for the message; empty for the whole server.
    let place: String

    var id: String { SkillsMarketModel.busyKey(skill.id, target) }
    var name: String { skill.name }
}
