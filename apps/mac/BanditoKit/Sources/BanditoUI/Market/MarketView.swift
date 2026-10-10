import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Marketplace mode: the services the agents can use. The connected ones come first, then the catalog to connect
/// more from. Connecting, configuring, checking and removing happen here; the sidebar picks the filter.
struct MarketView: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app

    @State private var integrations: [Integration] = []
    @State private var catalog: [IntegrationCatalogEntry] = []
    /// The last check of each integration in this session. The daemon keeps no check result.
    @State private var tests: [String: IntegrationTest] = [:]
    /// Integrations being checked now, by id.
    @State private var checking: Set<String> = []
    /// How each browser sign-in stands, by integration id (`integrations.oauth_status`).
    @State private var connections: [String: OAuthConnection] = [:]
    /// The server the lists above belong to. A switch to another server clears them before the new lists load.
    @State private var shownServer: UUID?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var error: UserFacingMessage?
    @State private var editing: IntegrationTarget?
    @State private var removing: Integration?
    /// The Bots and Skills pages: what the server offers.
    @State private var bots = BotsMarketModel()
    @State private var skills = SkillsMarketModel()
    /// The panel over the page (a bot or a skill), and whether a create or an install in it is running.
    @State private var panel: MarketPanelState?
    @State private var panelBusy = false
    @State private var removingSkill: SkillRemoval?

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 14, alignment: .top)]

    var body: some View {
        Group {
            if app.currentServer == nil {
                NoServerView(symbol: AppMode.market.systemImage)
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .overlay { panelOverlay }
        .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: panel)
        .task(id: loadKey) {
            await loadForCurrentServer()
        }
        .task(id: "\(loadKey)|\(tab.rawValue)") {
            await loadTab()
        }
        .onChange(of: tab) { _, _ in
            query = ""
            panel = nil
        }
        .confirmationDialog(
            L10n.Market.Skill.removeTitle(name: removingSkill?.name ?? ""),
            isPresented: Binding(get: { removingSkill != nil }, set: { if !$0 { removingSkill = nil } }),
            titleVisibility: .visible,
            presenting: removingSkill
        ) { removal in
            Button(L10n.Market.Skill.remove, role: .destructive) {
                Task { await removeSkill(removal) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { removal in
            Text(removal.target == .everyone
                ? L10n.Market.Skill.removeMessageEveryone
                : L10n.Market.Skill.removeMessageAgent(agent: removal.place))
        }
        .onChange(of: app.oauth.phase) { _, phase in
            if case .connected(_, let id) = phase { Task { await signedIn(id) } }
        }
        .banditoSheet(item: $editing, dismissOnOutsideClick: false) { target in
            if let server = app.currentServer {
                if case .custom = target {
                    CustomIntegrationSheet(
                        server: server, existingNames: integrations.map(\.name),
                        onChecked: { id, result in tests[id] = result },
                        onSaved: { await reload() })
                } else {
                    IntegrationEditor(
                        server: server, target: target, existingNames: integrations.map(\.name),
                        onChecked: { id, result in tests[id] = result },
                        onSaved: { await reload() })
                }
            }
        }
        .confirmationDialog(
            L10n.Integrations.removeTitle(name: removing?.name ?? ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { integration in
            Button(L10n.Integrations.remove, role: .destructive) {
                Task { await remove(integration) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Integrations.removeMessage)
        }
    }

    private var server: ServerModel? { app.currentServer }

    /// Reloads when the server changes, and when the connection of the current server comes up.
    private var loadKey: String {
        "\(server?.id.uuidString ?? "")|\(server?.info != nil)"
    }

    /// The pages this server offers, and the one in front.
    private var availableTabs: [MarketTab] {
        MarketTab.available { server?.supports($0) ?? false }
    }

    private var tab: MarketTab {
        MarketTab.effective(router.marketTab, available: availableTabs)
    }

    private var page: some View {
        let supported = server?.supports("integrations") ?? false
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: integrations, languageCode: ModelDescription.currentLanguageCode)
        let shown = MarketLogic.page(entries, filter: router.marketFilter, query: query)
        let empty = MarketLogic.emptyState(shown, filter: router.marketFilter, query: query)
        if tab == .services, supported, let open = MarketLogic.entry(withID: router.marketDetail, in: entries) {
            return AnyView(detailPage(open))
        }
        return AnyView(listPage(supported: supported, shown: shown, empty: empty))
    }

    private func detailPage(_ entry: MarketEntry) -> some View {
        MarketDetailView(
            entry: entry,
            languageCode: ModelDescription.currentLanguageCode,
            test: entry.integration.flatMap { tests[$0.id] },
            checking: entry.integration.map { checking.contains($0.id) } ?? false,
            connection: entry.integration.flatMap { connections[$0.id] },
            onBack: { router.marketDetail = nil },
            onConnect: { if let template = entry.template { connect(template) } },
            onSignInAgain: { if let integration = entry.integration { signInAgain(integration) } },
            onConfigure: { if let integration = entry.integration { editing = .edit(integration) } },
            onCheck: { if let integration = entry.integration { Task { await check(integration.id) } } },
            onRemove: { removing = entry.integration },
            onSetEnabled: { on in
                if let integration = entry.integration { Task { await setEnabled(integration, on) } }
            })
    }

    private func listPage(supported: Bool, shown: MarketPage, empty: MarketEmptyState?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(supported: supported)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == .bots {
                        botsContent
                    } else if tab == .skills {
                        skillsContent
                    } else if supported {
                        if !shown.connected.isEmpty {
                            SectionLabel(L10n.Integrations.connected)
                            connectedRow(shown.connected)
                        }
                        SectionLabel(L10n.Integrations.catalog)
                        if !shown.grid.isEmpty {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(shown.grid) { entry in
                                    catalogCard(entry)
                                }
                            }
                        } else if let empty {
                            emptyText(empty)
                        }
                        if let error {
                            UserFacingErrorView(message: error)
                        }
                    } else {
                        ServerUnavailable(server: server)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(supported: Bool) -> some View {
        let tabs = availableTabs
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Mode.market)
                        .font(BanditoFont.display(size: 24, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        // Unbounded is wide: in a narrow window the title shrinks instead of breaking inside the word.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if tabs.count == 1, supported {
                    // A server with only services keeps the one-row header.
                    searchField
                    addOwnButton
                }
            }
            if tabs.count > 1 {
                HStack(alignment: .center, spacing: 12) {
                    SegmentedPicker(
                        selection: Binding(
                            get: { tab },
                            set: { chosen in
                                guard chosen != router.marketTab else { return }
                                router.marketTab = chosen
                                router.marketDetail = nil
                                MarketTabStore.save(chosen)
                            }),
                        options: tabs.map { ($0, $0.title) }
                    )
                    .fixedSize()
                    Spacer(minLength: 12)
                    if tab != .services || supported {
                        searchField
                    }
                    if tab == .services, supported {
                        addOwnButton
                    }
                }
            }
        }
    }

    private var subtitle: String {
        switch tab {
        case .services: L10n.Market.subtitle
        case .bots: L10n.Market.Bots.subtitle
        case .skills: L10n.Market.Skills.subtitle
        }
    }

    private var addOwnButton: some View {
        Button(L10n.Integrations.addOwn) { editing = .custom }
            .banditoButton(.quiet())
            .fixedSize()
    }

    /// One capsule holds the lens and the field: the capsule draws the fill and the border, the field inside is plain.
    /// Focus shows as a cream ring on the capsule.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.Market.search, text: $query)
                .textFieldStyle(.plain)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .frame(width: 240, height: 32)
        .background(Capsule().fill(Color.Bandito.text.opacity(0.05)))
        .overlay(Capsule().strokeBorder(searchFocused ? Color.Bandito.text.opacity(0.3) : Color.Bandito.line, lineWidth: 1))
        .banditoAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: BanditoMotion.fast), value: searchFocused)
    }

    private func emptyText(_ state: MarketEmptyState) -> some View {
        Text(state == .noResults ? L10n.Market.noResults : L10n.Integrations.empty)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .padding(.vertical, 6)
    }

    // MARK: - bots and skills

    private var languageCode: String { ModelDescription.currentLanguageCode }

    @ViewBuilder
    private var botsContent: some View {
        BotsPage(
            model: bots, catalog: catalog, integrations: integrations, query: query, languageCode: languageCode,
            onView: { panel = .botDetail($0.id) },
            onCreate: { panel = .botCreate($0.id) },
            onRetry: { if let server { Task { await bots.load(from: server, force: true) } } })
        if let error {
            UserFacingErrorView(message: error)
        }
    }

    @ViewBuilder
    private var skillsContent: some View {
        SkillsPage(
            model: skills, query: query, languageCode: languageCode, agents: server?.agents ?? [],
            onView: { panel = .skillDetail($0.id) },
            onInstall: { panel = .skillInstall($0.id) },
            onRemoveEverywhere: { removingSkill = SkillRemoval(skill: $0, target: .everyone, place: "") },
            onRetry: { if let server { Task { await skills.load(from: server) } } })
        if let error {
            UserFacingErrorView(message: error)
        }
    }

    private func closePanel() {
        guard !panelBusy else { return }
        panel = nil
    }

    /// The panel over the page, if one is open: a bot's page or its create sheet, a skill's page or its install sheet.
    /// A panel whose bot or skill is gone (the server changed, the catalog reloaded) closes with the lookup failing.
    @ViewBuilder
    private var panelOverlay: some View {
        if let server, let panel {
            switch panel {
            case .botDetail(let id):
                if let template = bots.templates.first(where: { $0.id == id }) {
                    MarketPanel(width: 580, canClose: !panelBusy, onClose: closePanel) {
                        BotDetailPanel(
                            template: template, services: botServices(template),
                            skillNames: Dictionary(skills.skills.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                            languageCode: languageCode,
                            onClose: closePanel, onCreate: { self.panel = .botCreate(id) },
                            onConnect: { connect($0) })
                    }
                    .transition(.opacity)
                }
            case .botCreate(let id):
                if let template = bots.templates.first(where: { $0.id == id }) {
                    MarketPanel(width: 540, canClose: !panelBusy, onClose: closePanel) {
                        BotCreatePanel(
                            template: template, server: server, services: botServices(template),
                            languageCode: languageCode, creating: $panelBusy,
                            onClose: closePanel, onConnect: { connect($0) })
                        .id(template.id)
                    }
                    .transition(.opacity)
                }
            case .skillDetail(let id):
                if let skill = skills.skills.first(where: { $0.id == id }) {
                    MarketPanel(width: 580, canClose: !panelBusy, onClose: closePanel) {
                        SkillDetailPanel(
                            skill: skill, agents: server.agents, languageCode: languageCode, busy: skills.busy,
                            onClose: closePanel, onInstall: { self.panel = .skillInstall(id) },
                            onRemove: { target in
                                removingSkill = SkillRemoval(
                                    skill: skill, target: target,
                                    place: { if case .agent(let agent) = target { SkillLogic.agentName(agent, agents: server.agents) } else { "" } }())
                            })
                    }
                    .transition(.opacity)
                }
            case .skillInstall(let id):
                if let skill = skills.skills.first(where: { $0.id == id }) {
                    MarketPanel(width: 500, canClose: !panelBusy, onClose: closePanel) {
                        SkillInstallPanel(
                            skill: skill, agents: server.agents, installing: $panelBusy,
                            onInstall: { target in
                                await skills.change(skill.id, target: target, install: true, on: server)
                            },
                            onClose: closePanel)
                        .id(skill.id)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func botServices(_ template: BotTemplate) -> [BotLogic.Service] {
        BotLogic.services(of: template, catalog: catalog, integrations: integrations)
    }

    private func removeSkill(_ removal: SkillRemoval) async {
        guard let server else { return }
        if let failure = await skills.change(removal.skill.id, target: removal.target, install: false, on: server) {
            error = SkillText.message(for: failure)
        } else {
            error = nil
        }
    }

    /// Reads what the open page needs: the bot templates (and the skill names they point to), or the skills.
    private func loadTab() async {
        guard let server, server.info != nil else { return }
        switch tab {
        case .services:
            break
        case .bots:
            await bots.load(from: server)
            if server.supports("skills") { await skills.load(from: server) }
            let categories = BotLogic.categories(in: bots.templates)
            if router.marketBotCategories != categories { router.marketBotCategories = categories }
            if case .category(let name) = router.marketBotFilter, !categories.contains(name) {
                router.marketBotFilter = .all
            }
        case .skills:
            await skills.load(from: server)
            let categories = SkillLogic.categories(in: skills.skills)
            if router.marketSkillCategories != categories { router.marketSkillCategories = categories }
            if case .category(let name) = router.marketSkillFilter, !categories.contains(name) {
                router.marketSkillFilter = .all
            }
        }
    }

    // MARK: - cards

    /// The connected services in one row. Each card shows its address, the result of the last check, the switch that
    /// turns it on or off for the agents, and a menu: check, edit, remove.
    private func connectedRow(_ entries: [MarketEntry]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(entries) { entry in
                    if let integration = entry.integration {
                        connectedCard(entry, integration)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func connectedCard(_ entry: MarketEntry, _ integration: Integration) -> some View {
        let status = IntegrationStatus.of(
            integration, test: tests[integration.id], connection: connections[integration.id])
        return MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    MarketTile(entry: entry, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(MarketLogic.address(integration))
                            .font(BanditoFont.mono(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    menu(integration)
                }
                statusLine(status)
                if status == .needsLogin {
                    Button(L10n.Integrations.Oauth.signInAgain) { signInAgain(integration) }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
                Toggle(isOn: Binding(get: { integration.enabled }, set: { on in
                    Task { await setEnabled(integration, on) }
                })) {
                    Text(L10n.Market.availableToAgents)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
                .toggleStyle(BanditoToggleStyle())
            }
            .padding(14)
            .frame(width: 300, alignment: .topLeading)
        }
        .onTapGesture { router.marketDetail = entry.id }
    }

    private func menu(_ integration: Integration) -> some View {
        let busy = checking.contains(integration.id)
        return Menu {
            Button(busy ? L10n.Integrations.checking : L10n.Integrations.check) {
                Task { await check(integration.id) }
            }
            .disabled(busy || !integration.enabled)
            if integration.auth == .oauth {
                Button(L10n.Integrations.Oauth.signInAgain) { signInAgain(integration) }
            } else {
                Button(L10n.Integrations.edit) { editing = .edit(integration) }
            }
            Divider()
            Button(L10n.Integrations.remove, role: .destructive) { removing = integration }
        } label: {
            Image(systemName: "ellipsis")
        }
        .banditoButton(.icon(size: 26, label: L10n.Market.more))
        .fixedSize()
    }

    private func statusLine(_ status: IntegrationStatus) -> some View {
        IntegrationStatusLine(status: status)
    }

    private func catalogCard(_ entry: MarketEntry) -> some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MarketTile(entry: entry, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        if let publisher = entry.template?.publisher {
                            Text(publisher)
                                .font(BanditoFont.text(size: 11, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.description)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(L10n.Market.view) { router.marketDetail = entry.id }
                        .banditoButton(.quiet())
                        .fixedSize()
                    Spacer(minLength: 0)
                    cardActions(entry)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        }
        .onTapGesture { router.marketDetail = entry.id }
    }

    @ViewBuilder
    private func cardActions(_ entry: MarketEntry) -> some View {
        if let integration = entry.integration {
            Label {
                Text(L10n.Integrations.connected)
            } icon: {
                Image(systemName: "checkmark")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
            if integration.auth != .oauth {
                Button(L10n.Market.configure) { editing = .edit(integration) }
                    .banditoButton(.link)
                    .fixedSize()
            }
        } else if let template = entry.template {
            Button(L10n.Integrations.connect) { connect(template) }
                .banditoButton(.lightPill())
                .fixedSize()
        }
    }

    // MARK: - actions

    /// Clears what belongs to the previous server, then loads the current one.
    private func loadForCurrentServer() async {
        let id = server?.id
        if id != shownServer {
            shownServer = id
            integrations = []
            catalog = []
            router.marketCategories = []
            router.marketDetail = nil
            router.marketBotCategories = []
            router.marketSkillCategories = []
            router.marketBotFilter = .all
            router.marketSkillFilter = .all
            bots.reset()
            skills.reset()
            panel = nil
            panelBusy = false
            removingSkill = nil
            tests = [:]
            checking = []
            connections = [:]
            error = nil
        }
        await reload()
    }

    private func reload() async {
        guard let server, server.info != nil, server.supports("integrations") else { return }
        do {
            integrations = try await server.integrations()
            await reloadConnections(of: server)
            if catalog.isEmpty {
                catalog = try await server.integrationCatalog()
                router.marketCategories = MarketCategory.present(in: catalog)
                if case .category(let name) = router.marketFilter, !router.marketCategories.contains(name) {
                    router.marketFilter = .all
                }
            }
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    /// The state of each browser sign-in. A daemon without the feature has none; a failed read keeps the last answer.
    private func reloadConnections(of server: ServerModel) async {
        guard server.supports("integrations_oauth") else {
            connections = [:]
            return
        }
        if let list = try? await server.oauthStatuses() {
            connections = Dictionary(list.map { ($0.id, $0.connection) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// Connect: a service that signs in in the browser starts the sign-in; the others open the sheet of keys.
    private func connect(_ template: IntegrationCatalogEntry) {
        guard template.usesOAuth, let url = template.url else {
            editing = .catalog(template)
            return
        }
        guard let server else { return }
        guard server.supports("integrations_oauth") else {
            error = UserFacingMessage(text: L10n.Integrations.Oauth.needsUpdate(name: template.name))
            return
        }
        let draft = NewIntegration(name: template.id, kind: .http, url: url)
        Task { await app.oauth.begin(server: server, target: .draft(draft), name: template.name) }
    }

    private func signInAgain(_ integration: Integration) {
        guard let server else { return }
        // The name the card shows: a service's name, or the owner's own name for an own integration.
        let entry = MarketLogic.entries(catalog: catalog, integrations: integrations, languageCode: "en")
            .first { $0.integration?.id == integration.id }
        Task { await app.oauth.begin(server: server, target: .existing(id: integration.id), name: entry?.name ?? integration.name) }
    }

    /// A sign-in just ended well: the list is read again and the new service is checked, so its tools show.
    private func signedIn(_ id: String) async {
        await reload()
        await check(id)
    }

    private func setEnabled(_ integration: Integration, _ on: Bool) async {
        guard let server else { return }
        do {
            try await server.updateIntegration(integration.id, patch: IntegrationPatch(enabled: on))
            await reload()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func check(_ id: String) async {
        guard let server else { return }
        checking.insert(id)
        defer { checking.remove(id) }
        do {
            let result = try await server.testIntegration(id)
            tests[id] = result
            if result.needsLogin { await reloadConnections(of: server) }
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func remove(_ integration: Integration) async {
        guard let server else { return }
        do {
            try await server.removeIntegration(integration.id)
            tests[integration.id] = nil
            await reload()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

/// The surface of a Marketplace card: the Bandito surface with a hairline border, lighter while the pointer is on it.
struct MarketCardFrame<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .background(shape.fill(Color.Bandito.surface1))
            .overlay(shape.strokeBorder(hovering ? Color.Bandito.text.opacity(0.22) : Color.Bandito.line, lineWidth: 1))
            .contentShape(shape)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: hovering ? 14 : 0, y: hovering ? 8 : 0)
            .offset(y: hovering ? -2 : 0)
            .onHover { hovering = $0 }
            .banditoAnimation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
    }
}

/// The colour of a Marketplace tile. A catalog service has its brand colour (`accent`); an own integration, or a
/// service without one, takes a colour of the avatar palette chosen by a hash of its name, so it stays the same.
enum MarketTileStyle {
    /// The brand colour as 0xRRGGBB, if the entry has a valid one.
    static func accent(of entry: MarketEntry) -> UInt32? {
        entry.template?.accent.flatMap(AvatarHex.value)
    }

    /// A stable index into the avatar palette (FNV-1a; `hashValue` changes on every launch).
    static func paletteIndex(for name: String, count: Int = AvatarColor.allCases.count) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(max(count, 1)))
    }

    static func color(of entry: MarketEntry) -> Color {
        if let hex = accent(of: entry) { return Color(hex: hex) }
        return AvatarColor.allCases[paletteIndex(for: entry.name)].color
    }
}

/// The tile of a Marketplace entry: a rounded square in the service's colour with a soft vertical gradient (lighter on
/// top), a thin highlight on the upper edge, and a white symbol, or the first letter of the name for an own
/// integration. With `glow` it casts a soft shadow of its colour.
struct MarketTile: View {
    let entry: MarketEntry
    let size: CGFloat
    var glow = false

    var body: some View {
        MarketTileSurface(color: MarketTileStyle.color(of: entry), size: size, glow: glow) {
            if let template = entry.template {
                if let logo = ServiceLogo.image(for: template.id) {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.5, height: size * 0.5)
                } else {
                    Image(systemName: IntegrationSymbol.name(icon: template.icon, kind: template.kind))
                        .font(.system(size: size * 0.44, weight: .semibold))
                }
            } else {
                Text(String(entry.name.prefix(1)).uppercased())
                    .font(BanditoFont.display(size: size * 0.42, weight: 700))
            }
        }
    }
}

/// The look of every Marketplace tile (a service, a bot, a skill): a rounded square in one colour with a soft vertical
/// gradient (lighter on top), a thin highlight on the upper edge, and a white symbol. With `glow` it casts a soft
/// shadow of its colour.
struct MarketTileSurface<Content: View>: View {
    let color: Color
    let size: CGFloat
    var glow = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        content
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .background(
                shape.fill(color).overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.24), .clear, .black.opacity(0.14)],
                            startPoint: .top, endPoint: .bottom))))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
            .shadow(color: glow ? color.opacity(0.35) : .clear, radius: 16, y: 6)
    }
}

/// The result of the last check of an integration, in one line.
struct IntegrationStatusLine: View {
    let status: IntegrationStatus

    var body: some View {
        switch status {
        case .disabled:
            Text(L10n.Integrations.Status.disabled)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
        case .unchecked:
            Text(L10n.Integrations.Status.unchecked)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
        case .connected(let tools):
            Label {
                Text(L10n.Integrations.Status.connected(count: tools))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
        case .needsLogin:
            Label {
                Text(L10n.Integrations.Status.needsLogin)
            } icon: {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.signal)
        case .refreshError:
            Label {
                Text(L10n.Integrations.Status.refreshError)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.signal)
        case .failed(let failure):
            Label {
                Text(IntegrationFailureText.text(failure))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.danger)
        }
    }
}

/// Sidebar of the Marketplace. Each page has its own rows: services have All, Connected and the categories; bots have
/// All and the categories; skills have All, Installed and the categories. Picking one sets the page's filter in
/// `Router` and leaves the page of a service.
struct MarketSidebar: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app

    private var tab: MarketTab {
        let server = app.currentServer
        return MarketTab.effective(
            router.marketTab, available: MarketTab.available { server?.supports($0) ?? false })
    }

    private var categories: [String] {
        switch tab {
        case .services: router.marketCategories
        case .bots: router.marketBotCategories
        case .skills: router.marketSkillCategories
        }
    }

    private var current: MarketFilter {
        switch tab {
        case .services: router.marketFilter
        case .bots: router.marketBotFilter
        case .skills: router.marketSkillFilter
        }
    }

    private func choose(_ filter: MarketFilter) {
        switch tab {
        case .services: router.marketFilter = filter
        case .bots: router.marketBotFilter = filter
        case .skills: router.marketSkillFilter = filter
        }
        router.marketDetail = nil
    }

    var body: some View {
        let rows = tab.filterRows(categories: categories)
        let firstCategory = rows.first { if case .category = $0 { true } else { false } }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { filter in
                let selected = current == filter
                if filter == firstCategory {
                    Divider().padding(.vertical, 6).padding(.horizontal, 10)
                }
                Button {
                    choose(filter)
                } label: {
                    Text(filter.title)
                        .font(BanditoFont.text(size: 13, weight: selected ? 600 : 400))
                        .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Color.Bandito.text.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                }
                .banditoButton(.row(cornerRadius: 9))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// What the add and edit sheet was opened for.
enum IntegrationTarget: Identifiable {
    case catalog(IntegrationCatalogEntry)
    case custom
    case edit(Integration)

    var id: String {
        switch self {
        case .catalog(let entry): "catalog-\(entry.id)"
        case .custom: "custom"
        case .edit(let integration): "edit-\(integration.id)"
        }
    }
}

/// The words for a check failure, shared by the list and the sheet.
enum IntegrationFailureText {
    static func text(_ failure: IntegrationFailure) -> String {
        switch failure {
        case .missingProgram: L10n.Integrations.Failure.missingProgram
        case .rejected: L10n.Integrations.Failure.rejected
        case .unreachable: L10n.Integrations.Failure.unreachable
        case .timeout: L10n.Integrations.Failure.timeout
        case .other: L10n.Integrations.Failure.other
        }
    }
}

/// The symbol of an integration tile. The catalog names its icons; a program and a web address have their own.
enum IntegrationSymbol {
    static func name(icon: String?, kind: IntegrationKind) -> String {
        switch icon {
        case "github": "chevron.left.forwardslash.chevron.right"
        case "composio": "square.grid.2x2"
        case "linear": "square.stack.3d.up"
        case "playwright": "theatermasks"
        case "folder": "folder"
        case "globe": "globe"
        case "atlassian": "rectangle.3.group"
        case "stripe": "creditcard"
        case "database": "cylinder.split.1x2"
        case "cloud": "cloud"
        case "book": "book"
        case "search": "magnifyingglass"
        case "web": "safari"
        case "brain": "brain"
        case "steps": "list.number"
        case "branch": "arrow.triangle.branch"
        case "clock": "clock"
        default: kind == .http ? "network" : "puzzlepiece.extension"
        }
    }
}
