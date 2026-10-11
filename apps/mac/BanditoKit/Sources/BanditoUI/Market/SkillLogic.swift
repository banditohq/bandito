import BanditoKit
import Foundation

/// The rules of the Skills page: the categories, the filter and the search, where a skill stands on the server, and
/// where it can still be installed. Pure, so each rule is easy to test.
enum SkillLogic {
    /// The order of the sidebar. A category the daemon adds later comes after these.
    static let categoryOrder = ["dev", "ops", "research", "writing", "data", "design", "productivity"]

    static func categories(in skills: [SkillEntry]) -> [String] {
        let used = Set(skills.map(\.category))
        return categoryOrder.filter { used.contains($0) } + used.subtracting(categoryOrder).sorted()
    }

    /// The skills the filter keeps, then the ones the search keeps. The search reads the skill's name and its
    /// description in the app's language and in English; it ignores case and spaces at the ends.
    static func visible(
        _ skills: [SkillEntry], filter: MarketFilter, query: String, languageCode: String
    ) -> [SkillEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return skills.filter { skill in
            switch filter {
            case .all, .connected: true
            case .installed: State(skill).isInstalled
            case .myBots: false
            case .category(let name): skill.category == name
            }
        }.filter { skill in
            needle.isEmpty
                || skill.name.localizedCaseInsensitiveContains(needle)
                || skill.id.localizedCaseInsensitiveContains(needle)
                || skill.description(languageCode: languageCode).localizedCaseInsensitiveContains(needle)
                || skill.descriptionEn.localizedCaseInsensitiveContains(needle)
        }
    }

    /// The word on a card: nothing, installed for the server's user, or installed in the folders of some agents.
    enum Badge: Equatable {
        case none
        case installed
        case onAgents(Int)
    }

    /// Where a skill stands on this server, from the `installed` and `conflicts` of `skills.catalog`.
    struct State: Equatable {
        let installedForEveryone: Bool
        let installedAgents: [String]
        let conflictForEveryone: Bool
        let conflictAgents: [String]

        init(_ skill: SkillEntry) {
            installedForEveryone = skill.installed.user
            installedAgents = skill.installed.projects
            conflictForEveryone = skill.conflicts.user
            conflictAgents = skill.conflicts.projects
        }

        var isInstalled: Bool { installedForEveryone || !installedAgents.isEmpty }

        /// A folder with the skill's name that is not Bandito's, somewhere: the daemon will not replace it.
        var hasConflict: Bool { conflictForEveryone || !conflictAgents.isEmpty }

        /// "Installed" when it is for everyone (the server's user), else the number of agents that have it.
        var badge: Badge {
            if installedForEveryone { return .installed }
            return installedAgents.isEmpty ? .none : .onAgents(installedAgents.count)
        }
    }

    /// Where an install can go.
    enum Target: Hashable {
        /// The server's user: every agent that reads the user's skills.
        case everyone
        case agent(String)

        var scope: SkillScope {
            switch self {
            case .everyone: .user
            case .agent(let id): .agent(id)
            }
        }
    }

    /// Why a target is not offered.
    enum Block: Equatable {
        /// Bandito's copy is already there.
        case installed
        /// A folder of that name that is not Bandito's is there.
        case conflict
    }

    static func block(_ target: Target, for skill: SkillEntry) -> Block? {
        let state = State(skill)
        switch target {
        case .everyone:
            if state.conflictForEveryone { return .conflict }
            return state.installedForEveryone ? .installed : nil
        case .agent(let id):
            if state.conflictAgents.contains(id) { return .conflict }
            return state.installedAgents.contains(id) ? .installed : nil
        }
    }

    /// The target the install sheet starts on: the whole server when it is free, else the first agent that is.
    /// Nil when nothing is free.
    static func defaultTarget(for skill: SkillEntry, agents: [Agent]) -> Target? {
        if block(.everyone, for: skill) == nil { return .everyone }
        return agents.map { Target.agent($0.id) }.first { block($0, for: skill) == nil }
    }

    /// The skill can be installed somewhere.
    static func canInstall(_ skill: SkillEntry, agents: [Agent]) -> Bool {
        defaultTarget(for: skill, agents: agents) != nil
    }

    /// The name of an agent for a row: its name, or its id when the agent is gone.
    static func agentName(_ id: String, agents: [Agent]) -> String {
        agents.first { $0.id == id }?.name ?? id
    }

    /// Why an install or a remove was refused, for the reasons the person can act on (`error.data.reason`).
    enum Failure: Equatable {
        /// A folder of that name that is not Bandito's is in the way.
        case folderNotOurs
        case notInstalled
        case unsafePath
    }

    static func failure(for error: Error) -> Failure? {
        guard case .reason(let reason) = FailureKind.classify(error) else { return nil }
        switch reason {
        case "exists_not_ours", "not_ours": return .folderNotOurs
        case "not_installed": return .notInstalled
        case "unsafe_path": return .unsafePath
        default: return nil
        }
    }
}
