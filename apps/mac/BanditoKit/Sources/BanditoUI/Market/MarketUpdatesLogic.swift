import BanditoKit
import BanditoL10n
import Foundation

/// What the "update available" line of a connected service says.
enum UpdateLine: Equatable {
    /// A pinned package moved from one version to another.
    case versions(from: String, to: String)
    /// The template's address changed: an address has no version to show.
    case newAddress
    /// An update exists but the daemon named no usable versions.
    case plain

    init(_ update: TemplateUpdate) {
        let from = update.from?.trimmingCharacters(in: .whitespaces) ?? ""
        let to = update.to?.trimmingCharacters(in: .whitespaces) ?? ""
        if !from.isEmpty, !to.isEmpty {
            self = .versions(from: from, to: to)
        } else if from.isEmpty, to.isEmpty {
            self = .newAddress
        } else {
            self = .plain
        }
    }

    var text: String {
        switch self {
        case .versions(let from, let to): L10n.Market.Update.versions(from: from, to: to)
        case .newAddress: L10n.Market.Update.newAddress
        case .plain: L10n.Market.Update.available
        }
    }
}

extension SkillLogic {
    /// The places where the skill's copy is behind the catalog, in the order they are updated: the server's, then the
    /// agents'. An update is the install of the same skill in the same place.
    static func updateTargets(_ skill: SkillEntry) -> [Target] {
        var targets: [Target] = []
        if skill.updates.user, skill.installed.user { targets.append(.everyone) }
        for id in skill.updates.projects where skill.installed.projects.contains(id) {
            targets.append(.agent(id))
        }
        return targets
    }

    static func hasUpdate(_ skill: SkillEntry) -> Bool {
        !updateTargets(skill).isEmpty
    }
}

/// The suggestions of `integrations.recommend`, matched with the catalog.
enum RecommendationLogic {
    struct Item: Identifiable, Equatable {
        let template: IntegrationCatalogEntry
        let reasonKey: String
        let evidence: String

        var id: String { template.id }
    }

    /// The suggestions the app can show: a service the catalog knows and that is not connected by now (the list of
    /// connected services may be newer than the suggestions). At most six, in the daemon's order.
    static func items(
        _ recommendations: [IntegrationRecommendation], catalog: [IntegrationCatalogEntry], integrations: [Integration]
    ) -> [Item] {
        var seen = Set<String>()
        var items: [Item] = []
        for recommendation in recommendations {
            guard let template = catalog.first(where: { $0.id == recommendation.templateId }),
                !seen.contains(template.id),
                !integrations.contains(where: { MarketLogic.template(for: $0, in: catalog)?.id == template.id })
            else { continue }
            seen.insert(template.id)
            items.append(Item(template: template, reasonKey: recommendation.reasonKey, evidence: recommendation.evidence))
            if items.count == 6 { break }
        }
        return items
    }

    /// The reason in the app's words. A key this app does not know reads as a plain "found in the project".
    static func reasonText(_ key: String) -> String {
        switch key {
        case "recommend.reason.gitRemoteGithub": L10n.Recommend.Reason.gitRemoteGithub
        case "recommend.reason.gitRemoteGitlab": L10n.Recommend.Reason.gitRemoteGitlab
        case "recommend.reason.nextPackage": L10n.Recommend.Reason.nextPackage
        case "recommend.reason.netlifyToml": L10n.Recommend.Reason.netlifyToml
        case "recommend.reason.vercelJson": L10n.Recommend.Reason.vercelJson
        case "recommend.reason.sentryProperties": L10n.Recommend.Reason.sentryProperties
        case "recommend.reason.sentryPackage": L10n.Recommend.Reason.sentryPackage
        case "recommend.reason.sentryPython": L10n.Recommend.Reason.sentryPython
        case "recommend.reason.supabaseFolder": L10n.Recommend.Reason.supabaseFolder
        case "recommend.reason.supabasePackage": L10n.Recommend.Reason.supabasePackage
        case "recommend.reason.prismaSchema": L10n.Recommend.Reason.prismaSchema
        case "recommend.reason.wranglerToml": L10n.Recommend.Reason.wranglerToml
        case "recommend.reason.composePostgres": L10n.Recommend.Reason.composePostgres
        case "recommend.reason.linearFolder": L10n.Recommend.Reason.linearFolder
        case "recommend.reason.linearReadme": L10n.Recommend.Reason.linearReadme
        case "recommend.reason.posthogPackage": L10n.Recommend.Reason.posthogPackage
        case "recommend.reason.stripePackage": L10n.Recommend.Reason.stripePackage
        default: L10n.Recommend.Reason.other
        }
    }

    /// Every key the daemon documents, so a test can hold the translation to the list.
    static let knownKeys = [
        "gitRemoteGithub", "gitRemoteGitlab", "nextPackage", "netlifyToml", "vercelJson", "sentryProperties",
        "sentryPackage", "sentryPython", "supabaseFolder", "supabasePackage", "prismaSchema", "wranglerToml",
        "composePostgres", "linearFolder", "linearReadme", "posthogPackage", "stripePackage",
    ].map { "recommend.reason.\($0)" }

    /// The agent the row is for: the one selected in the window, else the last opened one on the server, else the first.
    /// Nil when the server has no agents.
    static func agent(selected: String?, remembered: String?, agents: [Agent]) -> Agent? {
        guard let id = LastOpenedAgent.resolve(selected: selected, remembered: remembered, agentIDs: agents.map(\.id))
        else { return nil }
        return agents.first { $0.id == id }
    }
}

/// The agents whose row of suggestions the person closed, per viewer, in the app's own defaults. A closed row stays
/// closed for that agent on that server; another agent has its own row.
enum RecommendationStore {
    static let key = "market.recommend.hidden.v1"

    private static func entry(server: String, agent: String) -> String { "\(server)|\(agent)" }

    static func isHidden(server: String, agent: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(entry(server: server, agent: agent))
    }

    static func hide(server: String, agent: String, defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: key) ?? []
        let item = entry(server: server, agent: agent)
        guard !list.contains(item) else { return }
        list.append(item)
        defaults.set(list, forKey: key)
    }
}
