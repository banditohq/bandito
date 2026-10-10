import Foundation
import Testing

@testable import BanditoKit

/// The wire of `agents.templates`, `agents.create_from_template` and `skills.*`, and the language rule of both
/// catalogs. The samples follow docs/ARCHITECTURE.md and the shape of the daemon's JSON files.
@MainActor
@Suite struct BotsWireTests {
    nonisolated static let templateJSON = ##"""
        {"id":"morning-digest","name_en":"Morning digest","name_ru":"Утренний дайджест",
         "description_en":"Short digest.","description_ru":"Короткий дайджест.",
         "long_en":"Long text.","long_ru":"Длинный текст.",
         "l10n":{"de":{"name":"Morgen-Überblick","description":"Kurz.","long":"Lang.","starter":"Los.","schedule_prompts":["Bereite vor."]},
                 "pt-BR":{"name":"Resumo da manhã","description":"Curto.","long":"Longo.","starter":"Vai.","schedule_prompts":["Prepare."]}},
         "category":"personal","icon":"newspaper","accent":"#6F8FB5","role_en":"Morning news digest",
         "system_prompt":"Reply in the language the owner writes in.","runtime":"claude","effort":"medium","capabilities":[],
         "integrations":[{"id":"fetch","required":true},{"id":"brave-search","required":false}],
         "skills":["commit"],
         "schedules":[{"cron":"0 8 * * 1-5","prompt_en":"Prepare.","prompt_ru":"Подготовь.","enabled_by_default":true}],
         "starter_en":"Make today's digest.","starter_ru":"Сделай сегодняшний дайджест."}
        """##

    nonisolated static let skillJSON = ##"""
        {"id":"commit","name":"commit","publisher":"getsentry",
         "source":{"repo":"getsentry/skills","path":"plugins/sentry-skills/skills/commit","commit":"0123456789abcdef","license":"Apache-2.0"},
         "category":"dev","description_en":"Write a commit.","description_ru":"Написать коммит.",
         "long_en":"Long.","long_ru":"Длинно.","warning_en":"Sentry format.","warning_ru":"Формат Sentry.",
         "l10n":{"de":{"description":"Commit schreiben.","long":"Lang."}},
         "runtimes":["claude"],"scripts":false,"files":["SKILL.md","LICENSE"],
         "installed":{"user":true,"projects":["a1","a2"]},"conflicts":{"user":false,"projects":["a3"]}}
        """##

    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: language

    @Test func templateTextFollowsTheAppLanguage() throws {
        let t = try decode(BotTemplate.self, Self.templateJSON)
        #expect(t.name(languageCode: "ru") == "Утренний дайджест")
        #expect(t.description(languageCode: "ru-RU") == "Короткий дайджест.")
        #expect(t.long(languageCode: "ru") == "Длинный текст.")
        #expect(t.starter(languageCode: "ru") == "Сделай сегодняшний дайджест.")
        #expect(t.name(languageCode: "de") == "Morgen-Überblick")
        #expect(t.name(languageCode: "de-AT") == "Morgen-Überblick")
        #expect(t.starter(languageCode: "de") == "Los.")
        #expect(t.name(languageCode: "pt-BR") == "Resumo da manhã")
        #expect(t.name(languageCode: "pt_br") == "Resumo da manhã")
        #expect(t.name(languageCode: "en") == "Morning digest")
        // A language the catalog does not have reads English.
        #expect(t.name(languageCode: "xx") == "Morning digest")
        #expect(t.description(languageCode: "ja") == "Short digest.")
        #expect(t.starter(languageCode: "xx") == "Make today's digest.")
    }

    @Test func templateSearchNamesHaveTheLocalAndTheEnglishName() throws {
        let t = try decode(BotTemplate.self, Self.templateJSON)
        #expect(t.searchNames(languageCode: "ru") == ["Утренний дайджест", "Morning digest"])
        #expect(t.searchNames(languageCode: "en") == ["Morning digest"])
        #expect(t.searchNames(languageCode: "xx") == ["Morning digest"])
    }

    @Test func skillTextFollowsTheAppLanguage() throws {
        let s = try decode(SkillEntry.self, Self.skillJSON)
        #expect(s.description(languageCode: "ru") == "Написать коммит.")
        #expect(s.description(languageCode: "de") == "Commit schreiben.")
        #expect(s.description(languageCode: "xx") == "Write a commit.")
        #expect(s.long(languageCode: "fr") == "Long.")
        // The warning exists in English and Russian only.
        #expect(s.warning(languageCode: "ru") == "Формат Sentry.")
        #expect(s.warning(languageCode: "de") == "Sentry format.")
    }

    @Test func theRequestLanguageIsTheDaemonsTag() {
        #expect(CatalogLanguage.requestCode("ru") == "ru")
        #expect(CatalogLanguage.requestCode("ru-RU") == "ru")
        #expect(CatalogLanguage.requestCode("en-GB") == "en")
        #expect(CatalogLanguage.requestCode("pt_br") == "pt-BR")
        #expect(CatalogLanguage.requestCode("pt-PT") == "pt-BR")
        #expect(CatalogLanguage.requestCode("zh-Hans") == "zh-Hans")
        #expect(CatalogLanguage.requestCode("zh-Hant") == "zh-Hans")
        #expect(CatalogLanguage.requestCode("de") == "de")
        #expect(CatalogLanguage.requestCode("xx") == "en")
        #expect(CatalogLanguage.requestCode("") == "en")
    }

    // MARK: decoding

    @Test func templateDecodesWithTheAppsDecoder() throws {
        let t = try decode(BotTemplate.self, Self.templateJSON)
        #expect(t.id == "morning-digest")
        #expect(t.roleEn == "Morning news digest")
        #expect(t.category == "personal")
        #expect(t.icon == "newspaper")
        #expect(t.accent == "#6F8FB5")
        #expect(t.runtimeKind == .claude)
        #expect(t.integrations == [BotIntegration(id: "fetch", required: true), BotIntegration(id: "brave-search", required: false)])
        #expect(t.skills == ["commit"])
        #expect(t.schedules.count == 1)
        #expect(t.schedules[0].cron == "0 8 * * 1-5")
        #expect(t.schedules[0].enabledByDefault)
        #expect(t.l10n["de"]?.schedulePrompts == ["Bereite vor."])
    }

    @Test func templateSurvivesMissingAndBrokenOptionalFields() throws {
        let bare = try decode(BotTemplate.self, #"{"id":"x","name_en":"X"}"#)
        #expect(bare.name(languageCode: "ru") == "X")
        #expect(bare.long(languageCode: "en") == "")
        #expect(bare.schedules.isEmpty)
        // A broken translation set drops itself; the template still lists.
        let broken = try decode(BotTemplate.self, #"{"id":"x","name_en":"X","l10n":{"de":5}}"#)
        #expect(broken.l10n.isEmpty)
        #expect(broken.name(languageCode: "de") == "X")
    }

    @Test func skillDecodesStateAndSource() throws {
        let s = try decode(SkillEntry.self, Self.skillJSON)
        #expect(s.claudeOnly)
        #expect(s.files == ["SKILL.md", "LICENSE"])
        #expect(s.source.license == "Apache-2.0")
        #expect(s.installed.user)
        #expect(s.installed.projects == ["a1", "a2"])
        #expect(!s.conflicts.user)
        #expect(s.conflicts.projects == ["a3"])
        #expect(s.source.shortReference == "getsentry/skills@0123456")
        #expect(s.source.url?.absoluteString == "https://github.com/getsentry/skills/tree/0123456789abcdef/plugins/sentry-skills/skills/commit")
    }

    @Test func skillSourceLinkRefusesAStrangeRepository() {
        #expect(SkillSource(repo: "a/b c", commit: "x").url == nil)
        #expect(SkillSource(repo: "../x", commit: "x").url == nil)
        #expect(SkillSource(repo: "", commit: "x").url == nil)
        #expect(SkillSource(repo: "a/b", commit: "").url == nil)
    }

    @Test func skillWithoutStateFieldsIsNotInstalled() throws {
        let s = try decode(SkillEntry.self, #"{"id":"s","name":"s","runtimes":["claude","codex"]}"#)
        #expect(!s.installed.user)
        #expect(s.installed.projects.isEmpty)
        #expect(!s.conflicts.user)
        #expect(!s.claudeOnly)
        #expect(s.warning(languageCode: "en") == nil)
    }

    @Test func creationDecodesTheAnswer() throws {
        let raw = ##"""
            {"agent":{"id":"b","name":"Digest","runtime":"claude","cwd":"/x"},"schedule_ids":["s1"],
             "skills_installed":["commit"],"missing_integrations":[{"id":"fetch","required":true}],
             "errors":[{"step":"skill","id":"x","message":"boom"},{"step":"schedule","index":2,"message":"cron"}]}
            """##
        let done = try decode(BotCreation.self, raw)
        #expect(done.agent?.id == "b")
        #expect(done.scheduleIds == ["s1"])
        #expect(done.skillsInstalled == ["commit"])
        #expect(done.missingIntegrations == [MissingIntegration(id: "fetch", required: true)])
        #expect(done.errors.count == 2)
        #expect(done.errors[0] == BotStepError(step: "skill", id: "x", message: "boom"))
        #expect(done.errors[1].index == 2)
        let bare = try decode(BotCreation.self, #"{"agent":null}"#)
        #expect(bare.agent == nil)
        #expect(bare.errors.isEmpty)
    }

    // MARK: encoding

    @Test func newBotEncodesSnakeCaseAndAlwaysSendsTheSchedules() throws {
        let body = try json(NewBot(templateId: "morning-digest", name: "Digest", language: "ru", schedules: []))
        #expect(body["template_id"] as? String == "morning-digest")
        #expect(body["name"] as? String == "Digest")
        #expect(body["language"] as? String == "ru")
        #expect((body["schedules"] as? [Int]) == [])
        #expect(body["runtime"] == nil)
        #expect(body["workspace_id"] == nil)
        let picked = try json(NewBot(templateId: "t", name: "N", runtime: "codex", language: "de", schedules: [0, 2]))
        #expect(picked["runtime"] as? String == "codex")
        #expect((picked["schedules"] as? [Int]) == [0, 2])
    }

    @Test func skillParamsAreSnakeCase() throws {
        let user = try json(SkillParams(skillID: "commit", scope: .user))
        #expect(user["skill_id"] as? String == "commit")
        #expect(user["scope"] as? String == "user")
        #expect(user["agent_id"] == nil)
        let agent = try json(SkillParams(skillID: "commit", scope: .agent("a1")))
        #expect(agent["scope"] as? String == "project")
        #expect(agent["agent_id"] as? String == "a1")
    }

    // MARK: through the server model

    private func connected(extra: [String: FakeTransport.Handler]) async -> (ServerModel, FakeTransport) {
        let fake = FakeTransport(handlers: daemonHandlers(extra: extra))
        let (model, _) = makeModel([fake])
        await model.connect()
        return (model, fake)
    }

    @Test func createBotSendsTheTemplateRequestAndAddsTheAgent() async throws {
        let answer = ##"{"agent":{"id":"b","name":"Digest","runtime":"claude","cwd":"/x"},"schedule_ids":[],"skills_installed":[],"missing_integrations":[],"errors":[]}"##
        let (model, fake) = await connected(extra: ["agents.create_from_template": { _ in answer }])
        let done = try await model.createBot(
            NewBot(templateId: "morning-digest", name: "Digest", language: "pt-BR", schedules: [0]))
        #expect(done.agent?.id == "b")
        #expect(model.agents.contains { $0.id == "b" })
        let sent = JSONRPC.requests(of: "agents.create_from_template", in: await fake.sentTexts())
        #expect(sent.count == 1)
        let params = try JSONSerialization.jsonObject(with: Data(try #require(JSONRPC.parse(sent[0])).paramsJSON.utf8)) as? [String: Any]
        #expect(params?["language"] as? String == "pt-BR")
        #expect((params?["schedules"] as? [Int]) == [0])
        await model.disconnect()
    }

    @Test func skillCallsUseTheirMethods() async throws {
        let (model, fake) = await connected(extra: [
            "skills.catalog": { _ in "[" + Self.skillJSON + "]" },
            "skills.install": { _ in #"{"path":"/p"}"# },
            "skills.remove": { _ in #"{"path":"/p"}"# },
        ])
        let list = try await model.skillCatalog()
        #expect(list.map(\.id) == ["commit"])
        try await model.installSkill("commit", scope: .agent("a1"))
        try await model.removeSkill("commit", scope: .user)
        let texts = await fake.sentTexts()
        let install = JSONRPC.requests(of: "skills.install", in: texts)
        #expect(install.count == 1)
        let installParams = try #require(JSONRPC.parse(install[0])).paramsJSON
        #expect(installParams.contains("\"agent_id\":\"a1\""))
        #expect(installParams.contains("\"scope\":\"project\""))
        let remove = JSONRPC.requests(of: "skills.remove", in: texts)
        #expect(try #require(JSONRPC.parse(remove[0])).paramsJSON.contains("\"scope\":\"user\""))
        await model.disconnect()
    }
}
