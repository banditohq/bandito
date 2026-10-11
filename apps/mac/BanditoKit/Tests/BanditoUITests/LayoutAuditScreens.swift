import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import Testing

@testable import BanditoUI

/// The screens of the layout audit that are not sheets or Settings sections: Server, Marketplace, onboarding.
extension LayoutAuditSnapshots {
    /// The area right of the 296 pt sidebar when the window is at its smallest (900 pt).
    static let modeArea: CGFloat = 604

    private static let hostStats = decode(
        HostStats.self,
        ##"""
        {"os":"Ubuntu 24.04 LTS","kernel":"6.8.0-45-generic","arch":"x86_64","hostname":"bandito-production-frankfurt-01",
         "cpus":8,"cpu_percent":42.5,"load":[1.2,0.9,0.7],"mem_total":17179869184,"mem_used":9663676416,
         "swap_total":2147483648,"swap_used":104857600,
         "disks":[{"mount":"/","total":214748364800,"used":96636764160},{"mount":"/home/bandito-service-user","total":536870912000,"used":429496729600}],
         "net_rx_bps":1200000,"net_tx_bps":340000,"net_supported":true,"uptime_s":1234567,
         "top_processes":[{"pid":10,"name":"claude","rss_bytes":734003200,"cpu_percent":22.5,"own":true,"own_safe":true},
                          {"pid":11,"name":"node","rss_bytes":402653184,"cpu_percent":4.0,"own":false,"own_safe":false}],
         "app_groups":[{"name":"Google Chrome","cpu_percent":18.0,"memory_bytes":2147483648,"process_count":9,"top":[]}]}
        """##)

    private static func seededMonitor() -> HostMonitor {
        let monitor = HostMonitor()
        monitor.stats = hostStats
        monitor.history = (0..<30).map { i in
            decode(
                HostPoint.self,
                "{\"t\":\(1_790_000_000_000 + i * 60_000),\"cpu\":\(20 + i % 7 * 5),\"mem_used\":\(9_000_000_000 + i * 20_000_000),\"net_rx_bps\":\(1_000_000 + i * 1000),\"net_tx_bps\":300000}")
        }
        monitor.ports = [
            decode(
                ListeningPort.self,
                ##"{"port":7878,"addr":"*","pid":1,"process":"bandito-daemon-with-a-long-name","owner":{"kind":"daemon"}}"##),
            decode(
                ListeningPort.self,
                ##"{"port":5173,"addr":"127.0.0.1","pid":22,"process":"node","owner":{"kind":"agent","id":"a1"}}"##),
        ]
        monitor.ownerGroups = [
            decode(
                ProcessOwner.self,
                ##"{"owner":{"kind":"agent","id":"a1"},"cpu_percent":22.5,"rss_bytes":734003200,"processes":[{"pid":10,"name":"claude","cmd":"claude --resume"}]}"##)
        ]
        return monitor
    }

    private static let hostFeatures = ["host", "update", "workspaces", "secrets", "backups", "schedules", "crew"]

    static let serverScreens: [AuditCase] = [
        AuditCase(name: "screen-missing-components", width: modeArea) { _ in
            AnyView(ScreenMissingComponents(components: ["x11vnc", "xdotool"], setup: SetupModel(), onInstall: {}))
        },
        // The shared failure view with "Подробнее" (collapsed): the row spans the whole 360 pt text column.
        AuditCase(name: "error-view-details", width: 360) { _ in
            AnyView(
                UserFacingErrorView(
                    message: UserFacingMessage(
                        text: L10n.Screen.startFailed,
                        technical: "cannot start the screen: Xvfb did not open :90 within 5 s", canRetry: true),
                    onRetry: {}))
        },
        AuditCase(name: "server-overview", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(ServerOverview(server: env.server, monitor: seededMonitor()))
        },
        AuditCase(name: "server-overview-offline", width: modeArea, scrolls: true) { env in
            AnyView(ServerOverview(server: env.server))
        },
        AuditCase(name: "server-updates", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(UpdatesView(server: env.server))
        },
        AuditCase(name: "server-workspaces", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(WorkspacesView())
        },
        AuditCase(name: "server-secrets", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(SecretsView(server: env.server))
        },
        AuditCase(name: "server-ports", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            let ports = decode(
                HostPorts.self,
                ##"""
                {"supported":true,"ports":[
                 {"port":7878,"addr":"*","pid":1,"process":"bandito-daemon-with-a-long-name","owner":{"kind":"daemon"}},
                 {"port":5173,"addr":"127.0.0.1","pid":22,"process":"node","owner":{"kind":"agent","id":"a1"}},
                 {"port":65535,"addr":"192.168.100.200","pid":2200,"process":"python3","owner":{"kind":"terminal","id":"t1"}}]}
                """##)
            return AnyView(PortsView(server: env.server, reply: ports))
        },
        AuditCase(name: "server-devices", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(DevicesView(server: env.server))
        },
        AuditCase(name: "server-backups", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(BackupsView(server: env.server))
        },
        AuditCase(name: "server-journal", width: modeArea, scrolls: true) { env in
            env.serverInfo(features: hostFeatures)
            return AnyView(ServerJournalView(server: env.server))
        },
    ]

    static let onboardingScreens: [AuditCase] = [
        AuditCase(name: "onboarding-welcome", width: 900, height: 640, selfSized: true, bleeds: true) { env in
            env.showOnboarding(.welcome)
            return AnyView(OnboardingFlow())
        },
        AuditCase(name: "onboarding-account", width: 900, height: 640, selfSized: true, bleeds: true) { env in
            env.showOnboarding(.account)
            return AnyView(OnboardingFlow())
        },
        AuditCase(name: "onboarding-server", width: 900, height: 640, selfSized: true, bleeds: true) { env in
            env.showOnboarding(.server)
            return AnyView(OnboardingFlow())
        },
        AuditCase(name: "onboarding-agent", width: 900, height: 640, selfSized: true, bleeds: true) { env in
            env.showOnboarding(.agent)
            return AnyView(OnboardingFlow())
        },
    ]

    static let botTemplate = decode(
        BotTemplate.self,
        ##"""
        {"id":"sentry-on-call","name_en":"Sentry on call","name_ru":"Дежурный по Sentry",
         "description_en":"Looks at new Sentry errors twice a weekday and writes what to fix first.",
         "description_ru":"Дважды в будни разбирает новые ошибки в Sentry и пишет, что чинить первым.",
         "long_en":"Watches the Sentry project of your team. Twice every weekday it reads the new errors, groups them by cause and writes a short list: what broke, how many people it touches and what to fix first. It never changes code on its own.",
         "long_ru":"Следит за проектом команды в Sentry. Дважды в будни читает новые ошибки, группирует их по причине и пишет короткий список: что сломалось, скольких это касается и что чинить первым. Сам код не меняет.",
         "category":"ops","icon":"exclamationmark.triangle","accent":"#C2573F",
         "runtime":"claude","integrations":[{"id":"sentry","required":true},{"id":"github","required":false},{"id":"linear","required":false}],
         "schedules":[{"cron":"0 9,15 * * 1-5","prompt_en":"x","prompt_ru":"х","enabled_by_default":false}],
         "starter_en":"Start","starter_ru":"Начать"}
        """##)

    static let skillEntry = decode(
        SkillEntry.self,
        ##"""
        {"id":"webapp-testing","name":"webapp-testing","publisher":"anthropics",
         "source":{"repo":"anthropics/skills","path":"skills/webapp-testing","commit":"0123456789abcdef","license":"Apache-2.0"},
         "category":"dev","description_en":"Test local web apps with Playwright.","description_ru":"Тестировать локальные веб-приложения через Playwright.",
         "warning_en":"Needs Python, Playwright and a browser. with_server.py runs the command you pass, so give it only your own dev server.",
         "warning_ru":"Нужны Python, Playwright и браузер. with_server.py запускает переданную команду, поэтому давайте ему только свой dev-сервер.","runtimes":["claude"],"files":["SKILL.md","LICENSE"]}
        """##)

    private static func botServices() -> [BotLogic.Service] {
        let catalog = [
            IntegrationCatalogEntry(
                id: "sentry", name: "Sentry", descriptionEn: "", descriptionRu: "", kind: .http, docsUrl: "", icon: "",
                accent: "#362D59"),
            IntegrationCatalogEntry(
                id: "github", name: "GitHub", descriptionEn: "", descriptionRu: "", kind: .http, docsUrl: "",
                icon: "github", accent: "#24292F"),
        ]
        return BotLogic.services(
            of: botTemplate, catalog: catalog,
            integrations: [Integration(id: "i", name: "github", kind: .http, url: "https://x")])
    }

    static let marketScreens: [AuditCase] = [
        AuditCase(name: "market-bot-detail", width: 580, height: 560, selfSized: true) { _ in
            AnyView(
                BotDetailPanel(
                    template: botTemplate, services: botServices(), skillNames: [:],
                    languageCode: L10n.locale.identifier, onClose: {}, onCreate: {}, onConnect: { _ in }))
        },
        AuditCase(name: "market-bot-create", width: 540, height: 560, selfSized: true) { env in
            AnyView(
                BotCreatePanel(
                    template: botTemplate, server: env.server, services: botServices(),
                    languageCode: L10n.locale.identifier, creating: .constant(false), onClose: {}, onConnect: { _ in }))
        },
        AuditCase(name: "market-skill-detail", width: 580, height: 560, selfSized: true) { _ in
            AnyView(
                SkillDetailPanel(
                    skill: skillEntry, agents: [], languageCode: L10n.locale.identifier, busy: [], onClose: {},
                    onInstall: {}, onRemove: { _ in }))
        },
        AuditCase(name: "market-skill-install", width: 500, selfSized: true) { _ in
            AnyView(
                SkillInstallPanel(
                    skill: skillEntry, agents: [], installing: .constant(false), onInstall: { _ in nil }, onClose: {}))
        },
        AuditCase(name: "market-service-detail", width: modeArea, height: 520, selfSized: true) { _ in
            let entry = MarketEntry(
                id: "catalog:linear", name: "Linear", description: "Issues and projects", template: linear,
                integration: Integration(id: "i1", name: "linear", kind: .http, url: "https://mcp.linear.app/mcp"))
            return AnyView(marketDetail(entry))
        },
        AuditCase(name: "market-service-detail-new", width: modeArea, height: 520, selfSized: true) { _ in
            let entry = MarketEntry(
                id: "catalog:filesystem", name: "Filesystem", description: "Read and write files", template: filesystem,
                integration: nil)
            return AnyView(marketDetail(entry))
        },
    ]

    // MARK: showcase

    private static let showcaseActions = MarketCardActions(
        open: { _ in }, connect: { _ in }, configure: { _ in }, check: { _ in }, remove: { _ in },
        signInAgain: { _ in }, setEnabled: { _, _ in }, update: { _ in })

    private static var showcaseEntries: [MarketEntry] {
        MarketLogic.entries(
            catalog: MarketGridSnapshots.catalog, integrations: MarketGridSnapshots.integrations,
            languageCode: L10n.locale.identifier)
    }

    /// A row of cards as a shelf draws it, cut by the window's edge (a ScrollView does not render offscreen).
    private static func shelfRow<Item: Identifiable, Card: View>(
        _ items: [Item], height: CGFloat, @ViewBuilder card: @escaping (Item) -> Card
    ) -> some View {
        HStack(alignment: .top, spacing: MarketShelfMetrics.gap) {
            ForEach(items) { item in card(item).frame(width: MarketShelfMetrics.cardWidth, height: height) }
        }
        .padding(.leading, MarketGridLayout.sidePadding)
        .padding(.vertical, 8)
        .frame(width: modeArea, alignment: .leading)
        .clipped()
    }

    static let marketShelfScreens: [AuditCase] = [
        // The headers with the longest words: a long category, a suggestion title with a long agent name, the "All" link.
        AuditCase(name: "market-shelves", width: modeArea, selfSized: true) { _ in
            let entries = showcaseEntries
            let dev = entries.filter { $0.category == "dev" }
            let connected = entries.filter(\.isConnected)
            let suggestion = RecommendationLogic.Item(
                template: MarketGridSnapshots.catalog[0], reasonKey: "vercel", evidence: "apps/web/vercel.json")
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    MarketShelfHeader(
                        title: L10n.Market.Filter.connected, symbol: MarketShelfSymbol.connected, count: connected.count,
                        onAll: {})
                    shelfRow(
                        connected,
                        height: MarketShelfMetrics.connectedCardHeight(hasStats: true, hasUpdate: false, needsLogin: false)
                    ) { entry in
                        if let integration = entry.integration {
                            MarketConnectedCard(
                                entry: entry, integration: integration, status: .connected(tools: 12),
                                statsLine: "12", updating: false, checking: false, actions: showcaseActions)
                        }
                    }
                    MarketShelfHeader(
                        title: L10n.Market.Recommend.title(agent: "Integration agent with a very long name"),
                        symbol: MarketShelfSymbol.recommended, count: 1, onAll: nil
                    ) {
                        Image(systemName: "xmark")
                    }
                    shelfRow([suggestion], height: MarketShelfMetrics.suggestionCardHeight) { item in
                        RecommendationCard(item: item, onConnect: {})
                    }
                    MarketShelfHeader(
                        title: MarketCategory.title("productivity"), symbol: MarketCategory.symbol("productivity"),
                        count: 14, onAll: {})
                    shelfRow(dev, height: MarketShelfMetrics.catalogCardHeight) { entry in
                        MarketCatalogCard(entry: entry, actions: showcaseActions)
                    }
                }
                .padding(.vertical, 12)
                .background(Color.Bandito.bg))
        },
        AuditCase(name: "market-category-page", width: modeArea, selfSized: true) { _ in
            let shown = showcaseEntries.filter { $0.category == "productivity" || $0.category == "dev" }
            return AnyView(
                VStack(alignment: .leading, spacing: 18) {
                    MarketPageHeader(
                        title: MarketCategory.title("productivity"), symbol: MarketCategory.symbol("productivity"),
                        count: shown.count, onBack: {})
                    MarketRowList(
                        items: shown, columns: 2, rowHeight: MarketShelfMetrics.catalogCardHeight,
                        inset: MarketGridLayout.sidePadding
                    ) { entry in
                        MarketCatalogCard(entry: entry, actions: showcaseActions)
                    }
                }
                .frame(width: modeArea, alignment: .topLeading)
                .padding(.vertical, 12)
                .background(Color.Bandito.bg))
        },
    ]

    private static func marketDetail(_ entry: MarketEntry) -> some View {
        MarketDetailView(
            entry: entry, languageCode: L10n.locale.identifier, test: nil, checking: false, connection: nil,
            onBack: {}, onConnect: {}, onSignInAgain: {}, onConfigure: {}, onCheck: {}, onRemove: {},
            onSetEnabled: { _ in }, tools: nil, journal: nil)
    }
}
