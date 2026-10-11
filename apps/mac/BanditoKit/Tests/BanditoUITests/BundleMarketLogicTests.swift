import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The sets of bots on the Bots page: the filter and the search, the bots of a set, the services the set needs, the
/// runtime and the request, and what the daemon answered.
@Suite struct BundleMarketLogicTests {
    private func bot(
        _ id: String, _ name: String, _ ru: String, category: String = "dev", description: String = "",
        integrations: [BotIntegration] = []
    ) -> BotTemplate {
        BotTemplate(
            id: id, nameEn: name, nameRu: ru, descriptionEn: description, descriptionRu: description + " ру",
            category: category, integrations: integrations)
    }

    private var templates: [BotTemplate] {
        [
            bot("reviewer", "Code reviewer", "Ревьюер кода", category: "dev", description: "Reads pull requests.",
                integrations: [BotIntegration(id: "github", required: true), BotIntegration(id: "git", required: false)]),
            bot("tasks", "Task manager", "Менеджер задач", category: "business",
                integrations: [BotIntegration(id: "linear", required: true), BotIntegration(id: "git", required: true)]),
            bot("digest", "Morning digest", "Утренний дайджест", category: "personal", description: "News."),
        ]
    }

    private func bundle(
        _ id: String, _ name: String, _ ru: String, category: String = "business", description: String = "",
        templates: [String]
    ) -> AgentBundle {
        AgentBundle(
            id: id, nameEn: name, nameRu: ru, descriptionEn: description, descriptionRu: description + " ру",
            l10n: ["de": BundleTranslation(name: name + " DE", description: "Beschreibung")],
            templates: templates, category: category)
    }

    private var sets: [AgentBundle] {
        [
            bundle("startup-team", "Startup team", "Команда стартапа", category: "business",
                description: "Tasks and review.", templates: ["tasks", "reviewer"]),
            bundle("personal", "Personal assistant", "Личный ассистент", category: "personal",
                description: "A morning digest.", templates: ["digest"]),
        ]
    }

    // MARK: filter and search

    @Test func everyFilterButMyBotsKeepsTheSets() {
        for filter in [MarketFilter.all, .connected, .installed] {
            let kept = BundleLogic.visible(sets, filter: filter, query: "", languageCode: "en")
            #expect(kept.map(\.id) == ["startup-team", "personal"], "\(filter)")
        }
        // A set is not a bot: My bots lists none.
        #expect(BundleLogic.visible(sets, filter: .myBots, query: "", languageCode: "en").isEmpty)
    }

    @Test func aCategoryKeepsTheSetsOfThatCategory() {
        let kept = BundleLogic.visible(sets, filter: .category("personal"), query: "", languageCode: "en")
        #expect(kept.map(\.id) == ["personal"])
    }

    @Test func theSearchReadsTheNamesInTheAppsLanguageAndInEnglishAndTheDescription() {
        #expect(BundleLogic.visible(sets, filter: .all, query: "команда", languageCode: "ru").map(\.id) == ["startup-team"])
        #expect(BundleLogic.visible(sets, filter: .all, query: "PERSONAL", languageCode: "de").map(\.id) == ["personal"])
        #expect(BundleLogic.visible(sets, filter: .all, query: "  morning  ", languageCode: "en").map(\.id) == ["personal"])
        #expect(BundleLogic.visible(sets, filter: .all, query: "tasks and", languageCode: "en").map(\.id) == ["startup-team"])
        #expect(BundleLogic.visible(sets, filter: .all, query: "нет такого", languageCode: "ru").isEmpty)
    }

    // MARK: members and services

    @Test func membersFollowTheSetsOrderAndLeaveOutUnknownTemplates() {
        let set = bundle("s", "S", "С", templates: ["reviewer", "gone", "tasks"])
        #expect(BundleLogic.members(of: set, templates: templates).map(\.id) == ["reviewer", "tasks"])
    }

    @Test func theNeedsOfTheSetAreTheUnionOfItsBotsEachOnceAndRequiredIfAnyBotRequiresIt() {
        let members = [templates[0], templates[1]]
        let needs = BundleLogic.needs(of: members)
        #expect(needs == [
            BotIntegration(id: "github", required: true),
            BotIntegration(id: "git", required: true),
            BotIntegration(id: "linear", required: true),
        ])
    }

    @Test func theSetsServicesMatchOnThisServerLikeABotsDo() {
        let catalog = [
            IntegrationCatalogEntry(
                id: "github", name: "GitHub", descriptionEn: "", descriptionRu: "", kind: .http,
                url: "https://api.github.example/mcp", docsUrl: "", icon: "github"),
        ]
        // Connected by its catalog address under another name; the others are missing.
        let byAddress = Integration(id: "i1", name: "My GitHub", kind: .http, url: "https://api.github.example/mcp")
        let services = BundleLogic.services(
            of: bundle("s", "S", "С", templates: ["reviewer", "tasks"]), templates: templates,
            catalog: catalog, integrations: [byAddress])
        #expect(services.map(\.id) == ["github", "git", "linear"])
        #expect(services.map(\.state) == [.connected, .missing, .missing])
        #expect(BotLogic.missingRequired(services).map(\.id) == ["git", "linear"])
    }

    // MARK: runtime and request

    @Test func theDefaultRuntimeIsClaudeWhenItIsReadyElseTheFirstReadyOne() {
        #expect(BundleLogic.defaultRuntime(available: [.codex, .claude]) == .claude)
        #expect(BundleLogic.defaultRuntime(available: [.codex]) == .codex)
        #expect(BundleLogic.defaultRuntime(available: []) == nil)
    }

    @Test func aRuntimeThatIsStillReadyIsKeptOtherwiseTheDefaultTakesOver() {
        #expect(BundleLogic.runtime(keeping: .codex, available: [.claude, .codex]) == .codex)
        #expect(BundleLogic.runtime(keeping: .codex, available: [.claude]) == .claude)
        #expect(BundleLogic.runtime(keeping: nil, available: []) == nil)
    }

    @Test func theRequestCarriesTheSetTheLanguageAndTheRuntime() {
        let set = sets[0]
        #expect(BundleLogic.request(bundle: set, runtime: nil, languageCode: "ru") == nil)
        #expect(
            BundleLogic.request(bundle: set, runtime: .claude, languageCode: "ru")
                == NewBundle(bundleId: "startup-team", language: "ru", runtime: "claude"))
        // The app's language as the daemon keys it.
        #expect(BundleLogic.request(bundle: set, runtime: .claude, languageCode: "pt_br")?.language == "pt-BR")
        #expect(BundleLogic.request(bundle: set, runtime: .claude, languageCode: "xx")?.language == "en")
    }

    // MARK: the answer

    private func agent(_ id: String, _ name: String) -> Agent {
        Agent(id: id, name: name, runtime: .claude, cwd: "/work")
    }

    private var creation: BundleCreation {
        BundleCreation(agents: [
            BundleEntry(templateId: "tasks", agent: agent("1", "Менеджер задач")),
            BundleEntry(templateId: "reviewer", error: "unknown runtime nope"),
            BundleEntry(templateId: "gone", agent: agent("2", "Docs"), error: "schedule 1: refused"),
        ])
    }

    @Test func theResultLinesFollowTheSetsOrderWithTheBotsNameInTheAppsLanguage() {
        let rows = BundleLogic.rows(of: creation, templates: templates, languageCode: "ru")
        #expect(rows.map(\.id) == ["tasks", "reviewer", "gone"])
        #expect(rows.map(\.name) == ["Менеджер задач", "Ревьюер кода", "gone"])
        #expect(rows.map(\.made) == [true, false, true])
        #expect(rows[1].problem == "unknown runtime nope")
        #expect(rows[2].problem == "schedule 1: refused")
    }

    @Test func theCountAndTheFirstAgentCountWhatExists() {
        // A bot with a problem after its creation still exists, so it counts and can be opened.
        #expect(BundleLogic.madeCount(creation) == 2)
        #expect(BundleLogic.firstAgent(creation)?.id == "1")
        let none = BundleCreation(agents: [BundleEntry(templateId: "tasks", error: "boom")])
        #expect(BundleLogic.madeCount(none) == 0)
        #expect(BundleLogic.firstAgent(none) == nil)
    }

    // MARK: after a failed request

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// An agent of a template, created `minutesAgo` before `now`.
    private func made(_ id: String, template: String?, minutesAgo: Double) -> Agent {
        let createdAt = Int64((now.timeIntervalSince1970 - minutesAgo * 60) * 1000)
        return Agent(id: id, name: "Bot \(id)", runtime: .claude, cwd: "/work", createdAt: createdAt, templateId: template)
    }

    @Test func aRetryMakesOnlyTheBotsWithoutARecentAgentOfTheirTemplate() {
        let members = [templates[0], templates[1], templates[2]]  // reviewer, tasks, digest
        let agents = [
            made("a", template: "reviewer", minutesAgo: 2),  // recent: counts as made
            made("b", template: "tasks", minutesAgo: 11),  // older than the window: an earlier team
            made("c", template: nil, minutesAgo: 1),  // made by hand: never counts
        ]
        #expect(BundleLogic.remaining(members: members, agents: agents, now: now).map(\.id) == ["tasks", "digest"])
        // Nothing made: all of them, in the set's order.
        #expect(BundleLogic.remaining(members: members, agents: [], now: now).map(\.id) == ["reviewer", "tasks", "digest"])
        // All made: nothing is left to ask for.
        let all = members.map { made("x-\($0.id)", template: $0.id, minutesAgo: 0) }
        #expect(BundleLogic.remaining(members: members, agents: all, now: now).isEmpty)
    }

    @Test func theNewestRecentAgentOfATemplateIsTheOneTakenAsMade() {
        let members = [templates[0]]
        let agents = [
            made("old", template: "reviewer", minutesAgo: 9),
            made("new", template: "reviewer", minutesAgo: 3),
        ]
        let entries = BundleLogic.recentEntries(members: members, agents: agents, now: now)
        #expect(entries.map(\.templateId) == ["reviewer"])
        #expect(entries.first?.agent?.id == "new")
    }

    @Test func theCombinedAnswerListsTheSetsBotsInItsOrderWithTheEarlierOnes() {
        let members = [templates[0], templates[1], templates[2]]
        let earlier = [BundleEntry(templateId: "reviewer", agent: agent("1", "Ревьюер"))]
        let retry = BundleCreation(agents: [
            BundleEntry(templateId: "digest", agent: agent("3", "Дайджест")),
            BundleEntry(templateId: "tasks", error: "unknown runtime nope"),
        ])
        let answer = BundleLogic.combined(members: members, earlier: earlier, made: retry)
        #expect(answer.agents.map(\.templateId) == ["reviewer", "tasks", "digest"])
        #expect(answer.agents[0].agent?.id == "1")
        #expect(answer.agents[1].error == "unknown runtime nope")
        #expect(answer.agents[2].agent?.id == "3")
    }

    @Test func aRowsOutcomeSaysWhetherTheBotExistsAndWhetherAStepFailed() {
        let creation = BundleCreation(agents: [
            BundleEntry(templateId: "tasks", agent: agent("1", "Задачи")),
            BundleEntry(templateId: "reviewer", error: "unknown runtime nope"),
            BundleEntry(templateId: "digest", agent: agent("2", "Дайджест"), error: "schedule 1: refused"),
        ])
        let rows = BundleLogic.rows(of: creation, templates: templates, languageCode: "en")
        #expect(rows.map(\.outcome) == [.made, .notMade, .madeWithProblem])
        // The daemon's words stay on the row, for the log and the tooltip.
        #expect(rows[1].problem == "unknown runtime nope")
    }
}
