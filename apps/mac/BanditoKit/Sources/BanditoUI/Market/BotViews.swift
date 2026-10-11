import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// The Bots page of the Marketplace: the cards, the page of one template, and the sheet that makes a bot from it.

extension MarketTileStyle {
    /// The colour of a tile from a `#RRGGBB` accent, or a stable palette colour of `name` when there is none.
    static func color(hex: String?, name: String) -> Color {
        if let value = hex.flatMap(AvatarHex.value) { return Color(hex: value) }
        return AvatarColor.allCases[paletteIndex(for: name)].color
    }
}

/// A tile with a template's SF Symbol on its accent colour.
struct BotTile: View {
    let template: BotTemplate
    let size: CGFloat
    var glow = false

    var body: some View {
        MarketTileSurface(
            color: MarketTileStyle.color(hex: template.accent, name: template.id), size: size, glow: glow
        ) {
            Image(systemName: template.icon)
                .font(.system(size: size * 0.44, weight: .semibold))
        }
    }
}

/// The logo of a service on its brand tile, small. Optional services are dimmer.
struct ServiceMiniLogo: View {
    let service: BotLogic.Service
    var size: CGFloat = 22

    var body: some View {
        MarketTileSurface(color: MarketTileStyle.color(hex: service.entry?.accent, name: service.id), size: size) {
            if let logo = ServiceLogo.image(for: service.id) {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.52, height: size * 0.52)
            } else if let entry = service.entry {
                Image(systemName: IntegrationSymbol.name(icon: entry.icon, kind: entry.kind))
                    .font(.system(size: size * 0.46, weight: .semibold))
            } else {
                Text(String(service.name.prefix(1)).uppercased())
                    .font(BanditoFont.display(size: size * 0.44, weight: 700))
            }
        }
        .opacity(service.required ? 1 : 0.6)
        .help(service.name)
        .accessibilityLabel(service.name)
    }
}

// MARK: - the page

struct BotsPage: View {
    let model: BotsMarketModel
    let catalog: [IntegrationCatalogEntry]
    let integrations: [Integration]
    let query: String
    let languageCode: String
    /// The agents of the server; the My bots filter takes the ones made from a template.
    let agents: [Agent]
    var onView: (BotTemplate) -> Void
    var onCreate: (BotTemplate) -> Void
    var onViewBundle: (AgentBundle) -> Void = { _ in }
    var onOpen: (Agent) -> Void
    var onRetry: () -> Void

    @Environment(Router.self) private var router

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        if router.marketBotFilter == .myBots {
            myBots
        } else {
            templateGrid
        }
    }

    /// The bots the owner made from a template, one card each. Empty: a short hint, or "nothing found" for a search.
    private var myBots: some View {
        let bots = BotLogic.myBots(agents: agents, templates: model.templates, query: query, languageCode: languageCode)
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel(L10n.Market.Filter.myBots)
            if !bots.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(bots) { bot in
                        MyBotCard(bot: bot, languageCode: languageCode, onOpen: { onOpen(bot.agent) })
                    }
                }
            } else {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.Market.MyBots.empty : L10n.Market.noResults)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.vertical, 6)
            }
        }
    }

    /// The templates of the sidebar's filter and the search: the catalog grid.
    private var templateGrid: some View {
        let shown = BotLogic.visible(
            model.templates, filter: router.marketBotFilter, query: query, languageCode: languageCode)
        let sets = BundleLogic.visible(
            model.bundles, filter: router.marketBotFilter, query: query, languageCode: languageCode)
        return VStack(alignment: .leading, spacing: 28) {
            if model.bundlesFailure != nil {
                bundlesFailedLine
            }
            if !sets.isEmpty {
                BundlesRow(bundles: sets, templates: model.templates, languageCode: languageCode, onView: onViewBundle)
            }
            catalogGrid(shown)
        }
    }

    /// The sets did not load: one quiet line with a retry. The single bots below are not affected.
    private var bundlesFailedLine: some View {
        HStack(spacing: 8) {
            Text(L10n.Market.Bundles.failed)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Button(L10n.Banner.retry, action: onRetry)
                .banditoButton(.link)
        }
    }

    /// The catalog of single bots: the grid, or the failure, or the empty and no-result texts.
    @ViewBuilder
    private func catalogGrid(_ shown: [BotTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(L10n.Market.Bots.catalog)
            if !shown.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(shown) { template in
                        BotCard(
                            template: template,
                            services: BotLogic.services(of: template, catalog: catalog, integrations: integrations),
                            languageCode: languageCode,
                            onView: { onView(template) },
                            onCreate: { onCreate(template) })
                    }
                }
            } else if let failure = model.failure {
                UserFacingErrorView(message: failure, onRetry: onRetry)
            } else if model.loaded {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.Market.Bots.empty : L10n.Market.noResults)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.vertical, 6)
            }
        }
    }
}

struct BotCard: View {
    let template: BotTemplate
    let services: [BotLogic.Service]
    let languageCode: String
    var onView: () -> Void
    var onCreate: () -> Void

    private static let logoLimit = 5

    var body: some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    BotTile(template: template, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(template.name(languageCode: languageCode))
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(MarketCategory.title(template.category))
                            .font(BanditoFont.text(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(template.description(languageCode: languageCode))
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                logos
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(L10n.Market.view, action: onView)
                        .banditoButton(.quiet())
                        .fixedSize()
                    Spacer(minLength: 0)
                    Button(L10n.Market.Bots.create, action: onCreate)
                        .banditoButton(.lightPill())
                        .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        }
        .onTapGesture(perform: onView)
    }

    /// The services the bot uses, as small logos in a row; the rest as a count. Room is kept when there are none.
    @ViewBuilder
    private var logos: some View {
        HStack(spacing: 6) {
            ForEach(services.prefix(Self.logoLimit)) { service in
                ServiceMiniLogo(service: service)
            }
            if services.count > Self.logoLimit {
                Text("+\(services.count - Self.logoLimit)")
                    .font(BanditoFont.text(size: 11, weight: 500))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .frame(height: 22)
    }
}

/// A bot the owner made from a template: its name, the template it came from, and Open, which shows its chat.
struct MyBotCard: View {
    let bot: BotLogic.MyBot
    let languageCode: String
    var onOpen: () -> Void

    @Environment(Router.self) private var router

    var body: some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    tile
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bot.agent.name)
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        if let templateName = bot.template?.name(languageCode: languageCode) {
                            Text(templateName)
                                .font(BanditoFont.text(size: 11, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Menu {
                        Button(L10n.Share.menu) { router.sheet = .share(.bot(agentID: bot.agent.id)) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text2)
                            .frame(width: 30, height: 26)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .banditoButton(.icon(size: 30, label: L10n.Share.menu))
                    .fixedSize()
                    Spacer(minLength: 0)
                    Button(L10n.Market.MyBots.open, action: onOpen)
                        .banditoButton(.lightPill())
                        .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        }
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder
    private var tile: some View {
        if let template = bot.template {
            BotTile(template: template, size: 36)
        } else {
            MarketTileSurface(color: MarketTileStyle.color(hex: nil, name: bot.agent.name), size: 36) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36 * 0.44, weight: .semibold))
            }
        }
    }
}

// MARK: - the page of one template

struct BotDetailPanel: View {
    let template: BotTemplate
    let services: [BotLogic.Service]
    /// Skill names by id, from the skills catalog when it is loaded.
    let skillNames: [String: String]
    let languageCode: String
    var onClose: () -> Void
    var onCreate: () -> Void
    var onConnect: (IntegrationCatalogEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            BotPanelHeader(template: template, languageCode: languageCode, subtitle: template.description(languageCode: languageCode))
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(template.long(languageCode: languageCode))
                        .font(BanditoFont.text(size: 13.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scheduleSection
                    if !services.isEmpty { servicesSection }
                    if !template.skills.isEmpty { skillsSection }
                }
                .padding(24)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)
            MarketPanelFooter {
                Spacer(minLength: 8)
                Button(L10n.Common.close, action: onClose)
                    .banditoButton(.quiet())
                    .fixedSize()
                Button(L10n.Market.Bots.create, action: onCreate)
                    .banditoButton(.signal())
                    .fixedSize()
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Market.Bot.Section.schedule)
            if template.schedules.isEmpty {
                Text(L10n.Market.Bot.noSchedule)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            } else {
                ForEach(Array(template.schedules.enumerated()), id: \.offset) { _, schedule in
                    ScheduleWordsRow(cron: schedule.cron, languageCode: languageCode)
                }
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Market.Bot.Section.services)
            ForEach(services) { service in
                BotServiceRow(service: service, onConnect: onConnect)
            }
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Market.Bot.Section.skills)
            Text(template.skills.map { skillNames[$0] ?? $0 }.joined(separator: " · "))
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The head of both panels: the tile, the name and a line under it.
struct BotPanelHeader: View {
    let template: BotTemplate
    let languageCode: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BotTile(template: template, size: 48, glow: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name(languageCode: languageCode))
                    .font(BanditoFont.display(size: 18, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

/// One scheduled run in words ("Weekdays at 8:00 AM"); an expression the app does not read shows as it is.
struct ScheduleWordsRow: View {
    let cron: String
    let languageCode: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            if let words = BotScheduleWords.words(cron: cron, languageCode: languageCode) {
                Text(words)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
            } else {
                Text(cron)
                    .font(BanditoFont.mono(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
            }
        }
    }
}

/// A service the bot uses: its logo, the name, Required or Optional, and Connected or the Connect button.
struct BotServiceRow: View {
    let service: BotLogic.Service
    var onConnect: (IntegrationCatalogEntry) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ServiceMiniLogo(service: BotLogic.Service(
                id: service.id, name: service.name, required: true, state: service.state, entry: service.entry))
            Text(service.name)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Chip(text: service.required ? L10n.Market.Bot.required : L10n.Market.Bot.optional, tone: .neutral)
            Spacer(minLength: 8)
            switch service.state {
            case .connected:
                Label {
                    Text(L10n.Integrations.Oauth.connected)
                } icon: {
                    Image(systemName: "checkmark")
                }
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.ok)
            case .off:
                Text(L10n.Market.Bot.serviceOff)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            case .missing:
                if let entry = service.entry {
                    Button(L10n.Integrations.connect) { onConnect(entry) }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
            }
        }
    }
}

// MARK: - making a bot

struct BotCreatePanel: View {
    let template: BotTemplate
    let server: ServerModel
    let services: [BotLogic.Service]
    let languageCode: String
    /// True while the daemon makes the bot: the panel then cannot be closed.
    @Binding var creating: Bool
    var onClose: () -> Void
    var onConnect: (IntegrationCatalogEntry) -> Void

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var draft: BotLogic.Draft
    @State private var error: UserFacingMessage?

    init(
        template: BotTemplate, server: ServerModel, services: [BotLogic.Service], languageCode: String,
        creating: Binding<Bool>, onClose: @escaping () -> Void, onConnect: @escaping (IntegrationCatalogEntry) -> Void
    ) {
        _creating = creating
        self.template = template
        self.server = server
        self.services = services
        self.languageCode = languageCode
        self.onClose = onClose
        self.onConnect = onConnect
        _draft = State(
            initialValue: BotLogic.Draft(
                template: template, languageCode: languageCode, existingNames: server.agents.map(\.name),
                available: BotLogic.availableRuntimes(server.runtimes)))
    }

    private var existingNames: [String] { server.agents.map(\.name) }
    private var available: [RuntimeKind] { BotLogic.availableRuntimes(server.runtimes) }

    var body: some View {
        VStack(spacing: 0) {
            BotPanelHeader(
                template: template, languageCode: languageCode, subtitle: L10n.Market.Bot.createTitle)
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    runtimeField
                    if !template.schedules.isEmpty { schedulesField }
                    servicesNotice
                    Text(L10n.Market.Bot.starterNote)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        UserFacingErrorView(message: error, onRetry: error.canRetry ? { create() } : nil)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)
            MarketPanelFooter {
                Spacer(minLength: 8)
                Button(L10n.Common.cancel, action: onClose)
                    .banditoButton(.quiet())
                    .disabled(creating)
                    .fixedSize()
                Button(creating ? L10n.Market.Bot.creating : L10n.Market.Bots.create) { create() }
                    .banditoButton(.signal())
                    .disabled(creating || !draft.canCreate(existing: existingNames))
                    .fixedSize()
            }
        }
        .task {
            // The server's programs may not be known yet; the draft takes the first one that is ready.
            _ = try? await server.refreshRuntimes()
        }
        .onChange(of: available) { _, now in
            draft.syncRuntime(preferred: template.runtimeKind, available: now)
        }
    }

    // MARK: fields

    private var nameField: some View {
        let problem = draft.nameProblem(existing: existingNames)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.AgentSheet.name)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.AgentSheet.name, text: $draft.name)
                .banditoField(error: problem != nil)
                .disabled(creating)
            if let problem {
                Text(Self.text(problem))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
    }

    @ViewBuilder
    private var runtimeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.AgentSheet.runtime)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            if available.isEmpty {
                Text(L10n.Market.Bot.noRuntime)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(BanditoPalette.peach)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                BanditoSelect(
                    selection: Binding(
                        get: { draft.runtime ?? available[0] },
                        set: { draft.runtime = $0 }),
                    sections: [
                        SelectSection(options: available.map { SelectOption(value: $0, title: $0.title) })
                    ],
                    label: L10n.AgentSheet.runtime, placeholder: "")
                .disabled(creating)
            }
        }
    }

    private var schedulesField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Market.Bot.Section.schedule)
            ForEach(Array(template.schedules.enumerated()), id: \.offset) { index, schedule in
                Toggle(isOn: Binding(
                    get: { draft.schedules.contains(index) },
                    set: { on in
                        if on { draft.schedules.insert(index) } else { draft.schedules.remove(index) }
                    })
                ) {
                    ScheduleWordsRow(cron: schedule.cron, languageCode: languageCode)
                }
                .toggleStyle(BanditoToggleStyle())
                .disabled(creating)
            }
        }
    }

    /// A required service that is not connected: the bot is made anyway, but cannot do its job until the service is
    /// connected, so the sheet says so and offers Connect. Optional ones only get a quiet line.
    @ViewBuilder
    private var servicesNotice: some View {
        let missing = BotLogic.missingRequired(services)
        let optional = BotLogic.missingOptional(services)
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(L10n.Market.Bot.missingRequired(names: missing.map(\.name).joined(separator: ", ")))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(BanditoPalette.peach)
                ForEach(missing) { service in
                    BotServiceRow(service: service, onConnect: onConnect)
                }
            }
        }
        if !optional.isEmpty {
            Text(L10n.Market.Bot.missingOptional(names: optional.map(\.name).joined(separator: ", ")))
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func text(_ problem: AgentNameRule.Problem) -> String {
        switch problem {
        case .empty: L10n.Onboarding.Agent.Err.empty
        case .tooLong: L10n.Market.Bot.nameTooLong
        case .badCharacters: L10n.Onboarding.Agent.Err.badCharacters
        case .duplicate: L10n.Onboarding.Agent.Err.duplicate
        }
    }

    // MARK: create

    private func create() {
        guard !creating, let request = draft.request(template: template, languageCode: languageCode) else { return }
        creating = true
        error = nil
        let name = request.name
        Task {
            do {
                let result = try await server.createBot(request)
                finish(result, name: name)
            } catch {
                self.error = UserFacingError.message(for: error)
                creating = false
            }
        }
    }

    /// The bot exists. If its server is still the one in front, its chat opens with the first message in the input
    /// field (not sent). Whatever failed after the agent was made is kept in a notice over the window.
    private func finish(_ result: BotCreation, name: String) {
        var problems = BotLogic.problems(of: result)
        if let agent = result.agent {
            if app.currentServer?.id == server.id {
                let starter = template.starter(languageCode: languageCode)
                if !starter.isEmpty { router.appendDraft(starter, for: agent.id) }
                router.selectAgent(agent.id, on: server)
                router.select(mode: .team)
                router.requestComposerFocus(agentID: agent.id)
            }
        } else if problems.isEmpty {
            problems = [L10n.Market.Bot.Error.unreadable]
        }
        if !problems.isEmpty {
            router.botNotice = BotNotice(agentName: result.agent?.name ?? name, problems: problems)
        }
        creating = false
        onClose()
    }
}

// MARK: - the notice after a bot with problems

/// What a bot's creation left to say. Shown over the window until closed.
struct BotNotice: Identifiable, Equatable {
    let id = UUID()
    let agentName: String
    let problems: [String]
}

struct BotNoticeToast: View {
    let notice: BotNotice
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.Market.Bot.noticeTitle(name: notice.agentName))
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                ForEach(Array(notice.problems.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .banditoButton(.icon(size: 24, label: L10n.Common.close))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color.Bandito.surface3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            onClose()
        }
    }
}
