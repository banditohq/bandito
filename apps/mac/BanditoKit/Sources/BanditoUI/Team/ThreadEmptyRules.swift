import BanditoL10n
import BanditoKit

/// The suggestions of an empty thread: what the person can write to a new agent to begin with. The ones the agent's
/// capabilities suggest come first, in a fixed order; the general ones fill up to `limit`. Pure, so the rules are tested
/// without a view (see `ThreadEmptyState`).
enum ThreadEmptyRules {
    /// One suggestion chip: an SF Symbol and the key of its line.
    struct Suggestion: Equatable, Identifiable {
        enum Key: String, CaseIterable {
            case listProject, fixErrors, news, meetTeam, capabilities, dayPlan
        }

        let key: Key
        let symbol: String

        var id: Key { key }

        var text: String {
            switch key {
            case .listProject: L10n.Thread.Empty.Suggest.listProject
            case .fixErrors: L10n.Thread.Empty.Suggest.fixErrors
            case .news: L10n.Thread.Empty.Suggest.news
            case .meetTeam: L10n.Thread.Empty.Suggest.meetTeam
            case .capabilities: L10n.Thread.Empty.Suggest.capabilities
            case .dayPlan: L10n.Thread.Empty.Suggest.dayPlan
            }
        }
    }

    /// The most chips the empty thread shows.
    static let limit = 4

    private static let listProject = Suggestion(key: .listProject, symbol: "folder")
    private static let fixErrors = Suggestion(key: .fixErrors, symbol: "wrench.and.screwdriver")
    private static let news = Suggestion(key: .news, symbol: "newspaper")
    private static let meetTeam = Suggestion(key: .meetTeam, symbol: "person.2")
    private static let capabilities = Suggestion(key: .capabilities, symbol: "sparkles")
    private static let dayPlan = Suggestion(key: .dayPlan, symbol: "checklist")

    /// The chips for `agent`, at most `limit`, with no key twice. A nil capability list means every capability
    /// (see `AgentCapability.set(from:)`); a capability the app does not know is ignored.
    static func suggestions(for agent: Agent) -> [Suggestion] {
        let enabled = AgentCapability.set(from: agent.capabilities)
        var candidates: [Suggestion] = []
        if enabled.contains(.terminal) || enabled.contains(.files) {
            candidates += [listProject, fixErrors]
        }
        if enabled.contains(.browser) {
            candidates.append(news)
        }
        if enabled.contains(.team) {
            candidates.append(meetTeam)
        }
        // The general ones, always offered: they fill the rest when the capabilities give fewer than `limit`.
        candidates += [capabilities, dayPlan]

        var picked: [Suggestion] = []
        for candidate in candidates where picked.count < limit && !picked.contains(where: { $0.key == candidate.key }) {
            picked.append(candidate)
        }
        return picked
    }
}
