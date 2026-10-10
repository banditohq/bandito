import BanditoKit
import Foundation

/// The rules of the bundles (teams of bots) on the Bots page and in their panel: the filter and the search, the bots
/// of a set, the services the set needs, the runtime, the request, and what the daemon answered. Pure, so each rule is
/// easy to test.
enum BundleLogic {
    /// The bundles the filter keeps, then the ones the search keeps. "My bots" keeps none: a set is not a bot. The
    /// search reads the name in the app's language and in English, and the description in the app's language.
    static func visible(
        _ bundles: [AgentBundle], filter: MarketFilter, query: String, languageCode: String
    ) -> [AgentBundle] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return bundles.filter { bundle in
            switch filter {
            case .all, .connected, .installed: true
            case .myBots: false
            case .category(let name): bundle.category == name
            }
        }.filter { bundle in
            needle.isEmpty
                || bundle.name(languageCode: languageCode).localizedCaseInsensitiveContains(needle)
                || bundle.nameEn.localizedCaseInsensitiveContains(needle)
                || bundle.description(languageCode: languageCode).localizedCaseInsensitiveContains(needle)
        }
    }

    /// The bots of the set, in the set's order. A template the catalog does not list is left out.
    static func members(of bundle: AgentBundle, templates: [BotTemplate]) -> [BotTemplate] {
        bundle.templates.compactMap { id in templates.first { $0.id == id } }
    }

    /// The services the bots of the set use, each once: required when any of those bots requires it.
    static func needs(of members: [BotTemplate]) -> [BotIntegration] {
        var order: [String] = []
        var required: [String: Bool] = [:]
        for need in members.flatMap(\.integrations) {
            if let known = required[need.id] {
                required[need.id] = known || need.required
            } else {
                order.append(need.id)
                required[need.id] = need.required
            }
        }
        return order.map { BotIntegration(id: $0, required: required[$0] ?? false) }
    }

    /// The services of the set, matched on this server the way a bot's are (`BotLogic.services`).
    static func services(
        of bundle: AgentBundle, templates: [BotTemplate], catalog: [IntegrationCatalogEntry], integrations: [Integration]
    ) -> [BotLogic.Service] {
        BotLogic.services(
            needs: needs(of: members(of: bundle, templates: templates)), catalog: catalog, integrations: integrations)
    }

    // MARK: runtime

    /// The runtime the set starts with: Claude Code when it is ready, else the first ready one (as a bot's draft).
    static func defaultRuntime(available: [RuntimeKind]) -> RuntimeKind? {
        AgentRuntimeChoice.pick(preferred: .claude, signedIn: available)
    }

    /// The runtime can change while the server's answer is still coming: keep a choice that is still ready, otherwise
    /// take the default.
    static func runtime(keeping current: RuntimeKind?, available: [RuntimeKind]) -> RuntimeKind? {
        if let current, available.contains(current) { return current }
        return defaultRuntime(available: available)
    }

    // MARK: create

    /// The body of `agents.create_bundle`: the set, the app's language as the daemon keys it, and the runtime every bot
    /// of the set runs on. Nil without a runtime: there is nothing to create with.
    static func request(bundle: AgentBundle, runtime: RuntimeKind?, languageCode: String) -> NewBundle? {
        guard let runtime else { return nil }
        return NewBundle(
            bundleId: bundle.id, language: CatalogLanguage.requestCode(languageCode), runtime: runtime.rawValue)
    }

    /// One line of the result: a bot the set made, or one it did not. `problem` is the daemon's words; a bot with an
    /// agent and a problem exists, but a step after its creation failed.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let agentName: String?
        let problem: String?

        var made: Bool { agentName != nil }
    }

    /// The result lines, in the set's order. The name is the bot's in the app's language, or the template id when the
    /// catalog no longer lists it.
    static func rows(of creation: BundleCreation, templates: [BotTemplate], languageCode: String) -> [Row] {
        creation.agents.map { entry in
            let name = templates.first { $0.id == entry.templateId }?.name(languageCode: languageCode) ?? entry.templateId
            return Row(id: entry.templateId, name: name, agentName: entry.agent?.name, problem: entry.error)
        }
    }

    /// How many bots of the set now exist (with or without a problem after their creation).
    static func madeCount(_ creation: BundleCreation) -> Int {
        creation.agents.filter { $0.agent != nil }.count
    }

    /// The first agent the set made: the panel opens its chat.
    static func firstAgent(_ creation: BundleCreation) -> Agent? {
        creation.agents.compactMap(\.agent).first
    }
}
