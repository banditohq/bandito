import Foundation

/// The agent the Team mode opened last on one server. Kept in UserDefaults per server, so coming back to a
/// server lands on the agent that was open there.
public enum LastOpenedAgent {
    public static func load(serverID: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(serverID: serverID))
    }

    public static func save(_ agentID: String, serverID: String, defaults: UserDefaults = .standard) {
        defaults.set(agentID, forKey: key(serverID: serverID))
    }

    /// The agent to show: the selected one when it belongs to this server, else the last opened one there,
    /// else the first in the list (`agentIDs` in sidebar order). Nil when the server has no agents.
    public static func resolve(selected: String?, remembered: String?, agentIDs: [String]) -> String? {
        if let selected, agentIDs.contains(selected) { return selected }
        if let remembered, agentIDs.contains(remembered) { return remembered }
        return agentIDs.first
    }

    static func key(serverID: String) -> String {
        "team.lastAgent.\(serverID).v1"
    }
}
