import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the Bots and Skills cards and the install sheet to PNG (no window, no app), to look at them.
/// ScrollView does not render offscreen, so the pages of one bot or skill are not here.
@MainActor
@Suite struct MarketSnapshots {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    private func template() throws -> BotTemplate {
        try decode(
            BotTemplate.self,
            ##"""
            {"id":"sentry-on-call","name_en":"Sentry on call","name_ru":"Дежурный по Sentry",
             "description_en":"Looks at new Sentry errors twice a weekday and writes what to fix first.",
             "description_ru":"Дважды в будни разбирает новые ошибки в Sentry и пишет, что чинить первым.",
             "long_en":"Long","long_ru":"Длинно","category":"ops","icon":"exclamationmark.triangle","accent":"#C2573F",
             "runtime":"claude","integrations":[{"id":"sentry","required":true},{"id":"github","required":false},{"id":"linear","required":false}],
             "schedules":[{"cron":"0 9,15 * * 1-5","prompt_en":"x","prompt_ru":"х","enabled_by_default":false}],
             "starter_en":"Start","starter_ru":"Начать"}
            """##)
    }

    private func services(_ template: BotTemplate) -> [BotLogic.Service] {
        let catalog = [
            IntegrationCatalogEntry(id: "sentry", name: "Sentry", descriptionEn: "", descriptionRu: "", kind: .http, docsUrl: "", icon: "", accent: "#362D59"),
            IntegrationCatalogEntry(id: "github", name: "GitHub", descriptionEn: "", descriptionRu: "", kind: .http, docsUrl: "", icon: "github", accent: "#24292F"),
        ]
        return BotLogic.services(of: template, catalog: catalog, integrations: [Integration(id: "i", name: "github", kind: .http, url: "https://x")])
    }

    private func skill(installed: SkillPlaces = SkillPlaces(), conflicts: SkillPlaces = SkillPlaces()) throws -> SkillEntry {
        var entry = try decode(
            SkillEntry.self,
            ##"""
            {"id":"webapp-testing","name":"webapp-testing","publisher":"anthropics",
             "source":{"repo":"anthropics/skills","path":"skills/webapp-testing","commit":"0123456789abcdef","license":"Apache-2.0"},
             "category":"dev","description_en":"Test local web apps with Playwright.","description_ru":"Тестировать локальные веб-приложения через Playwright.",
             "warning_en":"Needs Python, Playwright and a browser. with_server.py runs the command you pass, so give it only your own dev server.",
             "warning_ru":"Нужны Python, Playwright и браузер.","runtimes":["claude"],"files":["SKILL.md","LICENSE"]}
            """##)
        entry.installed = installed
        entry.conflicts = conflicts
        return entry
    }

    @Test func botCard() throws {
        let t = try template()
        let view = HStack(alignment: .top, spacing: 14) {
            BotCard(template: t, services: services(t), languageCode: "en", onView: {}, onCreate: {})
            BotCard(template: t, services: services(t), languageCode: "ru", onView: {}, onCreate: {})
        }
        .padding(24).background(Color.Bandito.bg)
        let url = try SnapshotSupport.render(view, "market-bot-cards", size: CGSize(width: 640, height: 260))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func skillCards() throws {
        let view = HStack(alignment: .top, spacing: 14) {
            SkillCard(skill: try! skill(), languageCode: "en", canInstall: true, onView: {}, onInstall: {}, onRemove: {})
            SkillCard(skill: try! skill(installed: SkillPlaces(user: true)), languageCode: "ru", canInstall: false, onView: {}, onInstall: {}, onRemove: {})
            SkillCard(skill: try! skill(installed: SkillPlaces(projects: ["a", "b"]), conflicts: SkillPlaces(user: true)), languageCode: "en", canInstall: true, onView: {}, onInstall: {}, onRemove: {})
        }
        .padding(24).background(Color.Bandito.bg)
        let url = try SnapshotSupport.render(view, "market-skill-cards", size: CGSize(width: 960, height: 280))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func installPanel() throws {
        let agent = try decode(Agent.self, #"{"id":"a1","name":"Forge","runtime":"claude","cwd":"/x"}"#)
        let view = SkillInstallPanel(
            skill: try skill(installed: SkillPlaces(user: true)), agents: [agent], installing: .constant(false),
            onInstall: { _ in nil }, onClose: {}
        )
        .frame(width: 500)
        .background(Color.Bandito.surface2)
        let url = try SnapshotSupport.render(view, "market-skill-install", size: CGSize(width: 500, height: 380))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
