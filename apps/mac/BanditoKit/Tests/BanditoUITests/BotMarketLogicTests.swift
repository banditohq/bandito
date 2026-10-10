import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The Bots page: the filter and the search, the services a bot needs, the create sheet's draft, and the words for a
/// schedule.
@Suite struct BotMarketLogicTests {
    private func bot(
        _ id: String, _ name: String, _ ru: String, category: String = "dev", description: String = "",
        runtime: String = "claude", integrations: [BotIntegration] = [], schedules: [BotSchedule] = []
    ) -> BotTemplate {
        BotTemplate(
            id: id, nameEn: name, nameRu: ru, descriptionEn: description, descriptionRu: description + " ру",
            starterEn: "Start", starterRu: "Начать", category: category, runtime: runtime,
            integrations: integrations, schedules: schedules)
    }

    private var templates: [BotTemplate] {
        [
            bot("reviewer", "Code reviewer", "Ревьюер кода", category: "dev", description: "Reads pull requests."),
            bot("digest", "Morning digest", "Утренний дайджест", category: "personal", description: "News."),
            bot("sentry", "Sentry on call", "Дежурный по Sentry", category: "ops"),
        ]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    // MARK: filter and search

    @Test func categoriesComeInTheSidebarOrderAndOnlyThePresentOnes() {
        #expect(BotLogic.categories(in: templates) == ["dev", "ops", "personal"])
        let extra = templates + [bot("x", "X", "Х", category: "hobby")]
        #expect(BotLogic.categories(in: extra) == ["dev", "ops", "personal", "hobby"])
    }

    @Test func aCategoryFilterKeepsItsTemplates() {
        let ids = BotLogic.visible(templates, filter: .category("ops"), query: "", languageCode: "en").map(\.id)
        #expect(ids == ["sentry"])
        #expect(BotLogic.visible(templates, filter: .all, query: "  ", languageCode: "en").count == 3)
    }

    @Test func theSearchReadsTheLocalNameTheEnglishNameAndTheLocalDescription() {
        func ids(_ query: String, _ language: String) -> [String] {
            BotLogic.visible(templates, filter: .all, query: query, languageCode: language).map(\.id)
        }
        #expect(ids("дайджест", "ru") == ["digest"])
        // The English name works in a Russian app too.
        #expect(ids("morning", "ru") == ["digest"])
        #expect(ids("MORNING", "en") == ["digest"])
        #expect(ids("pull", "en") == ["reviewer"])
        // The Russian name does not match in an English app.
        #expect(ids("дайджест", "en").isEmpty)
        #expect(ids("nothing here", "en").isEmpty)
    }

    @Test func searchAndFilterTogether() {
        let ids = BotLogic.visible(templates, filter: .category("dev"), query: "sentry", languageCode: "en")
        #expect(ids.isEmpty)
    }

    // MARK: services

    private let catalog = [
        IntegrationCatalogEntry(
            id: "linear", name: "Linear", descriptionEn: "", descriptionRu: "", kind: .http,
            url: "https://mcp.linear.app/mcp", docsUrl: "", icon: "linear"),
        IntegrationCatalogEntry(
            id: "fetch", name: "Fetch", descriptionEn: "", descriptionRu: "", kind: .stdio, command: "uvx",
            docsUrl: "", icon: ""),
    ]

    @Test func aServiceIsConnectedByNameOrByTheCatalogAddress() {
        let template = bot(
            "t", "T", "Т",
            integrations: [BotIntegration(id: "linear", required: true), BotIntegration(id: "fetch", required: false)])
        let byAddress = Integration(id: "i1", name: "My Linear", kind: .http, url: "https://mcp.linear.app/mcp")
        let services = BotLogic.services(of: template, catalog: catalog, integrations: [byAddress])
        #expect(services.map(\.state) == [.connected, .missing])
        #expect(services.map(\.name) == ["Linear", "Fetch"])
        #expect(services[0].entry?.id == "linear")
    }

    @Test func aTurnedOffIntegrationDoesNotCount() {
        let template = bot("t", "T", "Т", integrations: [BotIntegration(id: "fetch", required: true)])
        let off = Integration(id: "i2", name: "fetch", kind: .stdio, command: "uvx", enabled: false)
        let services = BotLogic.services(of: template, catalog: catalog, integrations: [off])
        #expect(services.map(\.state) == [.off])
        #expect(BotLogic.missingRequired(services).count == 1)
    }

    @Test func anUnknownServiceStillListsByItsId() {
        let template = bot("t", "T", "Т", integrations: [BotIntegration(id: "mystery", required: false)])
        let services = BotLogic.services(of: template, catalog: catalog, integrations: [])
        #expect(services.map(\.name) == ["mystery"])
        #expect(services[0].entry == nil)
        #expect(BotLogic.missingRequired(services).isEmpty)
        #expect(BotLogic.missingOptional(services).count == 1)
    }

    // MARK: runtimes

    @Test func onlyReadyRuntimesAreAvailable() throws {
        let statuses = try decode(
            [RuntimeStatus].self,
            #"[{"kind":"claude","installed":true,"logged_in":true},{"kind":"codex","installed":true,"logged_in":false},{"kind":"grok","installed":false},{"kind":"api","installed":true}]"#)
        #expect(BotLogic.availableRuntimes(statuses) == [.claude])
        let unknownLogin = try decode([RuntimeStatus].self, #"[{"kind":"codex","installed":true}]"#)
        #expect(BotLogic.availableRuntimes(unknownLogin) == [.codex])
        #expect(BotLogic.availableRuntimes([]).isEmpty)
    }

    // MARK: draft

    @Test func theDraftStartsFromTheTemplate() {
        let template = bot(
            "t", "Morning digest", "Утренний дайджест",
            schedules: [
                BotSchedule(cron: "0 8 * * 1-5", enabledByDefault: true),
                BotSchedule(cron: "0 18 * * 5", enabledByDefault: false),
                BotSchedule(cron: "0 9 * * 1", enabledByDefault: true),
            ])
        let draft = BotLogic.Draft(template: template, languageCode: "ru", existingNames: [], available: [.claude, .codex])
        #expect(draft.name == "Утренний дайджест")
        #expect(draft.runtime == .claude)
        #expect(draft.schedules == [0, 2])
    }

    @Test func theDraftTakesAnotherRuntimeWhenTheTemplatesIsNotReady() {
        let template = bot("t", "T", "Т", runtime: "codex")
        #expect(BotLogic.Draft(template: template, languageCode: "en", existingNames: [], available: [.codex, .claude]).runtime == .codex)
        #expect(BotLogic.Draft(template: template, languageCode: "en", existingNames: [], available: [.claude]).runtime == .claude)
        var none = BotLogic.Draft(template: template, languageCode: "en", existingNames: [], available: [])
        #expect(none.runtime == nil)
        #expect(!none.canCreate(existing: []))
        // The server's answer arrives later: the draft follows it, and keeps a choice that is still possible.
        none.syncRuntime(preferred: .codex, available: [.codex, .grok])
        #expect(none.runtime == .codex)
        none.runtime = .grok
        none.syncRuntime(preferred: .codex, available: [.codex, .grok])
        #expect(none.runtime == .grok)
    }

    @Test func theSuggestedNameIsValidAndFree() {
        let template = bot("t", "Code review / PR bot!", "Ревью")
        let name = BotLogic.Draft.suggestedName(template: template, languageCode: "en", existing: [])
        #expect(name == "Code review PR bot")
        #expect(AgentNameRule.problem(for: name, existing: [], maxLength: BotLogic.maxNameLength) == nil)
        // Taken: a number is added, case does not matter.
        let taken = BotLogic.Draft.suggestedName(template: template, languageCode: "en", existing: ["code review pr bot"])
        #expect(taken == "Code review PR bot 2")
        let twice = BotLogic.Draft.suggestedName(
            template: template, languageCode: "en", existing: ["Code review PR bot", "Code review PR bot 2"])
        #expect(twice == "Code review PR bot 3")
        // Long names are cut to 32 characters, with the number inside the limit.
        let long = bot("l", String(repeating: "Long ", count: 12), "x")
        let cut = BotLogic.Draft.suggestedName(template: long, languageCode: "en", existing: [])
        #expect(cut.count <= BotLogic.maxNameLength)
        let cutTaken = BotLogic.Draft.suggestedName(template: long, languageCode: "en", existing: [cut])
        #expect(cutTaken.count <= BotLogic.maxNameLength)
        #expect(cutTaken != cut)
        // A name with no usable character falls back to the English one, then to "Bot".
        #expect(BotLogic.Draft.suggestedName(template: bot("n", "Fallback", "!!!"), languageCode: "ru", existing: []) == "Fallback")
        #expect(BotLogic.Draft.suggestedName(template: bot("n", "!!!", "!!!"), languageCode: "en", existing: []) == "Bot")
    }

    @Test func theNameIsCheckedLikeANewAgentWithTheDaemonsLimit() {
        let template = bot("t", "T", "Т")
        var draft = BotLogic.Draft(template: template, languageCode: "en", existingNames: [], available: [.claude])
        draft.name = ""
        #expect(draft.nameProblem(existing: []) == .empty)
        draft.name = "Bad/Name"
        #expect(draft.nameProblem(existing: []) == .badCharacters)
        draft.name = String(repeating: "a", count: 33)
        #expect(draft.nameProblem(existing: []) == .tooLong)
        draft.name = String(repeating: "a", count: 32)
        #expect(draft.nameProblem(existing: []) == nil)
        draft.name = "Reviewer"
        #expect(draft.nameProblem(existing: ["reviewer"]) == .duplicate)
        #expect(draft.canCreate(existing: []))
        #expect(!draft.canCreate(existing: ["Reviewer"]))
    }

    @Test func theRequestHasTheLanguageTheNameTheRuntimeAndExactlyTheTickedSchedules() throws {
        let template = bot(
            "code-reviewer", "Reviewer", "Ревьюер",
            schedules: [
                BotSchedule(cron: "0 10 * * 1-5", enabledByDefault: false),
                BotSchedule(cron: "0 9 * * 1", enabledByDefault: true),
            ])
        var draft = BotLogic.Draft(template: template, languageCode: "pt-BR", existingNames: [], available: [.claude, .codex])
        draft.name = "  Reviewer  "
        draft.runtime = .codex
        draft.schedules = [1, 0]
        let request = try #require(draft.request(template: template, languageCode: "pt_BR"))
        #expect(request.templateId == "code-reviewer")
        #expect(request.name == "Reviewer")
        #expect(request.runtime == "codex")
        #expect(request.language == "pt-BR")
        #expect(request.schedules == [0, 1])
        draft.schedules = []
        #expect(try #require(draft.request(template: template, languageCode: "xx")).schedules.isEmpty)
        #expect(try #require(draft.request(template: template, languageCode: "xx")).language == "en")
        draft.runtime = nil
        #expect(draft.request(template: template, languageCode: "en") == nil)
    }

    // MARK: after creating

    @Test func stepErrorsBecomeLinesForTheNotice() throws {
        let done = try decode(
            BotCreation.self,
            #"{"agent":{"id":"a","name":"A","runtime":"claude","cwd":"/x"},"errors":[{"step":"skill","id":"commit","message":"boom"},{"step":"schedule","index":1,"message":"too often"},{"step":"agent","message":"avatar failed"}]}"#)
        let lines = BotLogic.problems(of: done)
        #expect(lines.count == 3)
        #expect(lines[0].contains("commit") && lines[0].contains("boom"))
        #expect(lines[1].contains("2") && lines[1].contains("too often"))
        #expect(lines[2] == "avatar failed")
        #expect(BotLogic.problems(of: BotCreation(agent: nil)).isEmpty)
    }

    // MARK: schedule words

    @Test func theCronsOfTheTemplatesAreRead() {
        #expect(BotScheduleWords.reading("0 8 * * 1-5") == .init(days: .weekdays, times: [480]))
        #expect(BotScheduleWords.reading("0 9,15 * * 1-5") == .init(days: .weekdays, times: [540, 900]))
        #expect(BotScheduleWords.reading("0 8,20 * * *") == .init(days: .every, times: [480, 1200]))
        #expect(BotScheduleWords.reading("0 9 * * 1") == .init(days: .list([1]), times: [540]))
        #expect(BotScheduleWords.reading("30 11 * * 5,7") == .init(days: .list([0, 5]), times: [690]))
        // What the plain reading does not cover is left to the view, as the expression.
        #expect(BotScheduleWords.reading("*/15 * * * *") == nil)
        #expect(BotScheduleWords.reading("0 9 1 * *") == nil)
        #expect(BotScheduleWords.reading("0 9 * *") == nil)
        #expect(BotScheduleWords.reading("0 25 * * *") == nil)
        #expect(BotScheduleWords.reading("0 9 * * 8") == nil)
    }

    @Test func theWordsCarryTheTimeAndTheDays() throws {
        let weekdays = try #require(BotScheduleWords.words(cron: "0 8 * * 1-5", languageCode: "en"))
        #expect(weekdays.contains("8:00"))
        let monday = try #require(BotScheduleWords.words(cron: "0 9 * * 1", languageCode: "en"))
        #expect(monday.contains("Mon"))
        #expect(monday.contains("9:00"))
        let twice = try #require(BotScheduleWords.words(cron: "0 8,20 * * *", languageCode: "en"))
        #expect(twice.contains("8:00") && twice.contains("PM"))
        #expect(BotScheduleWords.words(cron: "*/5 * * * *", languageCode: "en") == nil)
    }
}
