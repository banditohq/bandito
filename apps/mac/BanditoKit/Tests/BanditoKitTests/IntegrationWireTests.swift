import Foundation
import Testing

@testable import BanditoKit

/// The wire of `integrations.*`, the `integrations` field of an agent, and the schedule fields the app reads and writes.
/// The JSON samples follow docs/ARCHITECTURE.md and the daemon's serializers.
@Suite struct IntegrationWireTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    // MARK: integrations

    @Test func integrationReadsTheRowAndDefaultsMissingFields() throws {
        let full = try decode(
            Integration.self,
            #"{"id":"i1","name":"github","kind":"http","command":null,"args":[],"url":"https://x/mcp/","env":{},"headers":{"Authorization":"Bearer secret:GITHUB_TOKEN"},"enabled":true,"created_at":42}"#)
        #expect(full.kind == .http)
        #expect(full.url == "https://x/mcp/")
        #expect(full.headers["Authorization"] == "Bearer secret:GITHUB_TOKEN")
        #expect(full.createdAt == 42)

        let bare = try decode(Integration.self, #"{"id":"i2","name":"fetch","kind":"stdio","command":"uvx"}"#)
        #expect(bare.args.isEmpty)
        #expect(bare.env.isEmpty)
        #expect(bare.headers.isEmpty)
        #expect(bare.enabled)
    }

    @Test func catalogEntryReadsTheDetailFieldsAndFallsBackWithoutThem() throws {
        let full = try decode(
            IntegrationCatalogEntry.self,
            ##"{"id":"brave-search","name":"Brave Search","description_en":"Short.","description_ru":"Коротко.","kind":"stdio","command":"npx","args":["-y","@brave/x"],"env_keys":[{"key":"BRAVE_API_KEY","label_en":"Key","label_ru":"Ключ","secret":true,"value_template":"{secret}"}],"docs_url":"https://d.test","icon":"search","category":"web","accent":"#FB542B","publisher":"Brave","official":true,"homepage":"https://brave.test","long_en":"Long.","long_ru":"Длинно.","abilities_en":["A","B"],"abilities_ru":["А","Б"],"needs_en":"Node.","needs_ru":"Нода."}"##)
        #expect(full.category == "web")
        #expect(full.accent == "#FB542B")
        #expect(full.official)
        #expect(full.publisher == "Brave")
        #expect(full.envKeys.map(\.key) == ["BRAVE_API_KEY"])
        #expect(full.longDescription(languageCode: "ru") == "Длинно.")
        #expect(full.longDescription(languageCode: "fr") == "Long.")
        #expect(full.abilities(languageCode: "ru") == ["А", "Б"])
        #expect(full.needs(languageCode: "en") == "Node.")

        // An older daemon sends none of them.
        let bare = try decode(
            IntegrationCatalogEntry.self,
            #"{"id":"fetch","name":"Fetch","description_en":"Short.","description_ru":"Коротко.","kind":"stdio","docs_url":"https://d.test","icon":"globe"}"#)
        #expect(bare.category == nil)
        #expect(bare.accent == nil)
        #expect(!bare.official)
        #expect(bare.envKeys.isEmpty)
        #expect(bare.longDescription(languageCode: "ru") == "Коротко.")
        #expect(bare.abilities(languageCode: "en").isEmpty)
        #expect(bare.needs(languageCode: "en") == nil)
    }

    @Test func catalogEntryReadsTheTemplateAndPicksTheLanguage() throws {
        let entry = try decode(
            IntegrationCatalogEntry.self,
            #"{"id":"github","name":"GitHub","description_en":"Repos in English.","description_ru":"Репозитории.","kind":"http","url":"https://api.githubcopilot.com/mcp/","headers_keys":[{"key":"Authorization","label_en":"Personal access token","label_ru":"Токен","secret":true,"value_template":"Bearer {secret}"}],"docs_url":"https://github.com/github/github-mcp-server","icon":"github"}"#)
        #expect(entry.description(languageCode: "ru") == "Репозитории.")
        #expect(entry.description(languageCode: "ru-RU") == "Репозитории.")
        #expect(entry.description(languageCode: "de") == "Repos in English.")
        #expect(entry.headersKeys.count == 1)
        #expect(entry.headersKeys[0].secret)
        #expect(entry.headersKeys[0].valueTemplate == "Bearer {secret}")
        #expect(entry.headersKeys[0].label(languageCode: "ru") == "Токен")
        #expect(entry.headersKeys[0].label(languageCode: "en") == "Personal access token")
        #expect(entry.urlHint == nil)
        #expect(entry.args.isEmpty)
    }

    @Test func catalogTranslationsKeepTheirLanguageAndLabelKeys() throws {
        // `l10n` keys are language codes and label keys are env names. RPCClient.decoder converts snake_case keys, so
        // these must come through untouched.
        let entry = try decode(
            IntegrationCatalogEntry.self,
            #"{"id":"brave-search","name":"Brave Search","description_en":"Search.","description_ru":"Поиск.","kind":"stdio","docs_url":"https://d.test","icon":"search","env_keys":[{"key":"BRAVE_API_KEY","label_en":"Key","label_ru":"Ключ","secret":true,"value_template":"{secret}"}],"l10n":{"pt-BR":{"description":"Busca.","long":"Longo.","abilities":[],"needs":"Chave.","labels":{"BRAVE_API_KEY":"Chave da API"}},"zh-Hans":{"description":"搜索。","long":"长。","abilities":[],"needs":"密钥。","labels":{"BRAVE_API_KEY":"密钥"}}}}"#)
        #expect(Set(entry.l10n.keys) == ["pt-BR", "zh-Hans"])
        #expect(entry.l10n["pt-BR"]?.labels == ["BRAVE_API_KEY": "Chave da API"])
        #expect(entry.l10n["zh-Hans"]?.labels == ["BRAVE_API_KEY": "密钥"])
        #expect(entry.envKeys[0].key == "BRAVE_API_KEY")
        #expect(entry.label(for: entry.envKeys[0], languageCode: "pt-BR") == "Chave da API")
        #expect(entry.description(languageCode: "zh-Hans") == "搜索。")
    }

    @Test func catalogTemplatePicksTheTextOfTheAppLanguage() throws {
        let entry = try decode(
            IntegrationCatalogEntry.self,
            #"{"id":"exa","name":"Exa","description_en":"Search.","description_ru":"Поиск.","long_en":"Long.","long_ru":"Длинно.","abilities_en":["A","B"],"abilities_ru":["А","Б"],"needs_en":"Key.","needs_ru":"Ключ.","kind":"http","url":"https://mcp.exa.ai/mcp","headers_keys":[{"key":"x-api-key","label_en":"Key","label_ru":"Ключ","secret":true,"value_template":"{secret}"}],"docs_url":"https://d.test","icon":"search","l10n":{"de":{"description":"Suche.","long":"Lang.","abilities":["Ai","Bi"],"needs":"Schlüssel.","labels":{"x-api-key":"Schlüssel"}},"pt-BR":{"description":"Busca.","long":"","abilities":["Aa","Bb"],"needs":"Chave.","labels":{}}}}"#)
        // A translation is used for its language.
        #expect(entry.description(languageCode: "de") == "Suche.")
        #expect(entry.longDescription(languageCode: "de") == "Lang.")
        #expect(entry.abilities(languageCode: "de") == ["Ai", "Bi"])
        #expect(entry.needs(languageCode: "de") == "Schlüssel.")
        #expect(entry.label(for: entry.headersKeys[0], languageCode: "de") == "Schlüssel")
        // Russian has its own fields.
        #expect(entry.description(languageCode: "ru") == "Поиск.")
        #expect(entry.abilities(languageCode: "ru") == ["А", "Б"])
        #expect(entry.label(for: entry.headersKeys[0], languageCode: "ru") == "Ключ")
        // A language without a translation reads in English.
        #expect(entry.description(languageCode: "ko") == "Search.")
        #expect(entry.abilities(languageCode: "ko") == ["A", "B"])
        #expect(entry.label(for: entry.headersKeys[0], languageCode: "ko") == "Key")
        // The app's code is matched without case or underscore, and an empty field falls back to English.
        #expect(entry.description(languageCode: "pt_BR") == "Busca.")
        #expect(entry.longDescription(languageCode: "pt-BR") == "Long.")
        #expect(entry.label(for: entry.headersKeys[0], languageCode: "pt-BR") == "Key")
        #expect(entry.description(languageCode: "DE") == "Suche.")

        // A translation the daemon left fields out of reads as empty, and the rest falls back to English.
        let partial = try decode(
            IntegrationCatalogEntry.self,
            #"{"id":"fetch","name":"Fetch","description_en":"Short.","description_ru":"Коротко.","kind":"stdio","docs_url":"https://d.test","icon":"globe","l10n":{"fr":{"description":"Court."}}}"#)
        #expect(partial.description(languageCode: "fr") == "Court.")
        #expect(partial.longDescription(languageCode: "fr") == "Court.")
        #expect(partial.abilities(languageCode: "fr").isEmpty)
        #expect(partial.needs(languageCode: "fr") == nil)

        // A malformed `l10n` drops the translations and keeps the template.
        let broken = try decode(
            IntegrationCatalogEntry.self,
            #"{"id":"fetch","name":"Fetch","description_en":"Short.","description_ru":"Коротко.","kind":"stdio","docs_url":"https://d.test","icon":"globe","l10n":"oops"}"#)
        #expect(broken.l10n.isEmpty)
        #expect(broken.description(languageCode: "de") == "Short.")
    }

    @Test func testAnswerReadsToolsOrTheError() throws {
        let ok = try decode(IntegrationTest.self, #"{"ok":true,"tools":["list_repos","get_issue"]}"#)
        #expect(ok.ok)
        #expect(ok.tools == ["list_repos", "get_issue"])
        #expect(ok.error == nil)

        let failed = try decode(IntegrationTest.self, #"{"ok":false,"tools":[],"error":"npx: command not found"}"#)
        #expect(!failed.ok)
        #expect(failed.error == "npx: command not found")
    }

    @Test func addRequestLeavesOutEmptyOptionalFields() throws {
        let plain = try json(NewIntegration(name: "fetch", kind: .stdio, command: "uvx", args: ["mcp-server-fetch"]))
        #expect(plain["name"] as? String == "fetch")
        #expect(plain["kind"] as? String == "stdio")
        #expect(plain["command"] as? String == "uvx")
        #expect((plain["args"] as? [String]) == ["mcp-server-fetch"])
        #expect(plain["url"] == nil)
        #expect(plain["env"] == nil)
        #expect(plain["headers"] == nil)
        #expect(plain["enabled"] as? Bool == true)

        let http = try json(NewIntegration(
            name: "linear", kind: .http, url: "https://mcp.linear.app/mcp",
            headers: ["Authorization": "Bearer secret:LINEAR_API_KEY"]))
        #expect(http["command"] == nil)
        #expect(http["args"] == nil)
        #expect((http["headers"] as? [String: String]) == ["Authorization": "Bearer secret:LINEAR_API_KEY"])
    }

    @Test func patchSendsClearAsNullAndLeavesUnsetFieldsOut() throws {
        let untouched = try json(IntegrationPatch(enabled: false))
        #expect(untouched.keys.sorted() == ["enabled"])
        #expect(untouched["enabled"] as? Bool == false)

        let cleared = try json(IntegrationPatch(command: .clear, url: .set("https://x.test/mcp")))
        #expect(cleared.keys.sorted() == ["command", "url"])
        #expect(cleared["command"] is NSNull)
        #expect(cleared["url"] as? String == "https://x.test/mcp")
    }

    @Test func updateParamsCarryTheIdBesideThePatchFields() throws {
        let params = try json(IntegrationUpdateParams(id: "i9", patch: IntegrationPatch(name: "gh", env: ["A": "1"])))
        #expect(params["id"] as? String == "i9")
        #expect(params["name"] as? String == "gh")
        #expect((params["env"] as? [String: String]) == ["A": "1"])
        #expect(params["enabled"] == nil)
    }

    // MARK: agents

    @Test func agentReadsIntegrationsAndNullMeansEveryEnabledOne() throws {
        let some = try decode(
            Agent.self, #"{"id":"a","name":"n","runtime":"claude","cwd":"/x","integrations":["i1","i2"]}"#)
        #expect(some.integrations == ["i1", "i2"])

        let all = try decode(Agent.self, #"{"id":"a","name":"n","runtime":"claude","cwd":"/x","integrations":null}"#)
        #expect(all.integrations == nil)

        let old = try decode(Agent.self, #"{"id":"a","name":"n","runtime":"claude","cwd":"/x"}"#)
        #expect(old.integrations == nil)
    }

    @Test func agentPatchSendsIntegrationsOnlyWhenSet() throws {
        let untouched = try json(AgentPatch(paused: true))
        #expect(untouched["integrations"] == nil)

        let picked = try json(AgentPatch(integrations: .set(["i2"])))
        #expect((picked["integrations"] as? [String]) == ["i2"])

        let every = try json(AgentPatch(integrations: .clear))
        #expect(every["integrations"] is NSNull)
    }

    @Test func createSendsIntegrationsOnlyWhenPicked() throws {
        let plain = try json(NewAgent(name: "n", runtime: .claude, cwd: "/x"))
        #expect(plain["integrations"] == nil)

        let picked = try json(NewAgent(name: "n", runtime: .claude, cwd: "/x", integrations: ["i1"]))
        #expect((picked["integrations"] as? [String]) == ["i1"])
    }

    // MARK: schedules

    @Test func scheduleReadsTitleAndTheWordsInBothLanguages() throws {
        let raw = #"{"id":"s1","agent_id":"a","cron":"*/15 * * * *","tz":"UTC","prompt":"почта","enabled":true,"created_at":1,"title":"Почта","human_en":"every 15 minutes","human_ru":"каждые 15 минут"}"#
        let s = try decode(Schedule.self, raw)
        #expect(s.title == "Почта")
        #expect(s.humanText(languageCode: "ru") == "каждые 15 минут")
        #expect(s.humanText(languageCode: "en") == "every 15 minutes")
        #expect(s.humanText(languageCode: "de") == "every 15 minutes")

        let old = try decode(
            Schedule.self, #"{"id":"s2","agent_id":"a","cron":"0 9 * * *","tz":"UTC","prompt":"p","enabled":false,"created_at":1}"#)
        #expect(old.title == nil)
        #expect(old.humanText(languageCode: "ru") == nil)
    }

    @Test func scheduleUpdateSendsTitleClearAsNull() throws {
        let renamed = try json(ScheduleUpdateParams(id: "s1", title: .set("Отчёт")))
        #expect(renamed["title"] as? String == "Отчёт")
        #expect(renamed["cron"] == nil)

        let cleared = try json(ScheduleUpdateParams(id: "s1", cron: "0 9 * * *", title: .clear))
        #expect(cleared["title"] is NSNull)
        #expect(cleared["cron"] as? String == "0 9 * * *")

        let untouched = try json(ScheduleUpdateParams(id: "s1", enabled: false))
        #expect(untouched.keys.sorted() == ["enabled", "id"])
    }
}
