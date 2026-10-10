import BanditoDesign
import BanditoKit
import SwiftUI

/// The option lists of the selects, built from plain values, so their rules are tested without models or views. A view
/// maps its models to these values; the colours and icons that depend on the design are set here.
public enum SelectChoices {
    // MARK: Servers

    /// A server as the switcher lists it.
    public struct ServerRow: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var address: String
        public var isOnline: Bool
        /// The daemon has a newer release to install.
        public var hasUpdate: Bool

        public init(id: UUID, name: String, address: String, isOnline: Bool, hasUpdate: Bool) {
            self.id = id
            self.name = name
            self.address = address
            self.isOnline = isOnline
            self.hasUpdate = hasUpdate
        }
    }

    /// One row per server, in the order given. An update is said in the subtitle, after the address. The dot is only
    /// drawn for a server with an update; other rows keep the clear dot so the names line up.
    public static func servers(_ rows: [ServerRow], updateText: String) -> [SelectOption<UUID>] {
        rows.map { row in
            SelectOption(
                value: row.id, title: row.name,
                subtitle: row.hasUpdate ? "\(row.address) · \(updateText)" : row.address,
                icon: "circle.fill",
                tint: row.hasUpdate ? Color.Bandito.signal : Color.clear,
                help: row.hasUpdate ? updateText : nil)
        }
    }

    // MARK: Workplaces

    /// A container the agent can run in.
    public struct Place: Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The shared server, then the containers. The shared server is off when the agent already runs there; the
    /// container the agent is in is off, so it is not picked again.
    public static func workplaces(
        sharedTitle: String, sharedEnabled: Bool, containers: [Place], currentID: String
    ) -> [SelectOption<String>] {
        [SelectOption(value: Workspace.sharedID, title: sharedTitle, isEnabled: sharedEnabled)]
            + containers.map { place in
                SelectOption(value: place.id, title: place.name, isEnabled: place.id != currentID)
            }
    }

    /// A new agent's place: an existing container that is gone falls back to a new one. Other choices stay as they are.
    public static func workplace(_ choice: WorkplaceChoice, containerIDs: [String]) -> WorkplaceChoice {
        if case .existing(let id) = choice, !containerIDs.contains(id) {
            return .new
        }
        return choice
    }

    // MARK: Languages

    /// The "system" option first when given, then each language with its own name and, when known, its name in the
    /// current interface language.
    public static func languages(
        system: SelectOption<String>?, entries: [(code: String, native: String)], localizedName: (String) -> String?
    ) -> [SelectOption<String>] {
        (system.map { [$0] } ?? []) + entries.map { entry in
            SelectOption(value: entry.code, title: entry.native, subtitle: localizedName(entry.code))
        }
    }

    // MARK: Approvals

    /// A title and the line that says what it means.
    public struct Described: Equatable, Sendable {
        public var title: String
        public var subtitle: String

        public init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// Allow, Ask, Deny in that order, each with its icon and the colour of its behaviour pill in the rules table.
    public static func approvalActions(
        allow: Described, ask: Described, deny: Described
    ) -> [SelectOption<RuleAction>] {
        [
            SelectOption(
                value: .allow, title: allow.title, subtitle: allow.subtitle,
                icon: "checkmark.circle", tint: Color(hex: 0xC8DCC3)),
            SelectOption(
                value: .ask, title: ask.title, subtitle: ask.subtitle,
                icon: "hand.raised", tint: Color.Bandito.signal),
            SelectOption(
                value: .deny, title: deny.title, subtitle: deny.subtitle,
                icon: "xmark.octagon", tint: Color.Bandito.danger),
        ]
    }

    /// "All agents" (value "*"), then each agent by name with a dot in its avatar colour.
    public static func scopes(
        allAgentsTitle: String, agents: [(id: String, name: String, tint: Color?)]
    ) -> [SelectOption<String>] {
        [SelectOption(value: "*", title: allAgentsTitle, icon: "person.2")]
            + agents.map { agent in
                SelectOption(value: agent.id, title: agent.name, icon: "circle.fill", tint: agent.tint)
            }
    }

    /// A rule's scope after the agents change: "*" stays, an agent that is still there stays, and an agent that is gone
    /// becomes "all agents".
    public static func scope(_ scope: String, agentIDs: [String]) -> String {
        scope == "*" || agentIDs.contains(scope) ? scope : "*"
    }
}
