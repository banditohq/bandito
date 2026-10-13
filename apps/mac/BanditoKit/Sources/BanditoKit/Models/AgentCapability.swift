import BanditoL10n
import Foundation

/// What an agent may do on the server, as the "What it may do" chips show it. The wire names are sent with
/// `agents.create` and `agents.update`. Until the daemon has the field it ignores them, so nothing is enforced yet.
public enum AgentCapability: String, CaseIterable, Identifiable, Sendable {
    /// The raw values are the wire names the daemon uses (`Agent.capabilities`).
    case terminal, files, browser, team, screen

    public var id: String { rawValue }

    /// Every capability on: what an agent may do when the daemon sends no list.
    public static let allOn: Set<AgentCapability> = Set(allCases)

    /// The set an agent's wire list stands for. `nil` (no list from the daemon) means everything; unknown names are
    /// ignored, so a newer daemon's capability does not break an older app.
    public static func set(from wire: [String]?) -> Set<AgentCapability> {
        guard let wire else { return allOn }
        return Set(wire.compactMap(AgentCapability.init(rawValue:)))
    }

    /// The wire list for a set, in the order of the chips.
    public static func wire(_ enabled: Set<AgentCapability>) -> [String] {
        allCases.filter(enabled.contains).map(\.rawValue)
    }

    /// The set after one chip is clicked: on becomes off and off becomes on. Other chips are not touched.
    public static func toggled(_ enabled: Set<AgentCapability>, _ capability: AgentCapability) -> Set<AgentCapability> {
        var next = enabled
        if next.contains(capability) {
            next.remove(capability)
        } else {
            next.insert(capability)
        }
        return next
    }

    /// The capabilities the server cannot give, each with the reason its chip shows. The screen works on Linux servers
    /// only: a daemon that answered its info without the `screen` feature has none. Before the info comes nothing is
    /// known, so nothing is marked.
    public static func unavailable(infoKnown: Bool, supports: (String) -> Bool) -> [AgentCapability: String] {
        guard infoKnown, !supports("screen") else { return [:] }
        return [.screen: L10n.Screen.unsupported]
    }

    public var title: String {
        switch self {
        case .terminal: L10n.Capability.terminal
        case .files: L10n.Capability.files
        case .browser: L10n.Capability.browser
        case .team: L10n.Capability.crew
        case .screen: L10n.Capability.screen
        }
    }
}
