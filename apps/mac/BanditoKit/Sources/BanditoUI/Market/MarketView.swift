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
    /// Services that an update from the template is running for, by integration id.
    @State private var updating: Set<String> = []
    /// "Suited to the project": what the daemon suggested for `recommendedFor`, and a counter that bumps when the person
    /// closes a row, so the view reads the stored choice again.
    @State private var recommendations: [IntegrationRecommendation] = []
    @State private var hideTick = 0
    /// The "Tools" section of the open service: the tools its last check listed, by integration id, and the ones whose
    /// mode or words are being saved.
    @State private var toolLists: [String: [IntegrationTool]] = [:]
    @State private var toolsSaving: Set<String> = []
    @State private var toolsError: UserFacingMessage?
    /// Calls of the last day by service name, for the cards; and the journal of the open service, by name.
    @State private var callStats: [String: IntegrationCallStats] = [:]
    @State private var journals: [String: CallJournal] = [:]
    @State private var journalLoading: Set<String> = []
    @State private var journalError: UserFacingMessage?

    /// How many cards a row holds, from the width of the scroll view; written only when it changes.
    @State private var columns = 3
    /// The height of the scroll view in 8 pt steps: the space under the last block lets it reach the top.
    @State private var viewportHeight: CGFloat = 0
    /// Which block is in view, from the real positions of the anchors (a plain object: no view state per scroll step).
    @State private var tracker = MarketSectionTracker()
    /// The entries and the page for the last inputs, so the body does not rebuild them on every pass.
    @State private var memo = MarketListMemo()

    var body: some View {
        Group {
            if app.currentServer == nil {
                NoServerView(symbol: AppMode.market.systemImage)
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The ground takes no clicks, so the title band behind the mode gets the empty space (double-click zooms).
        .background { Color.Bandito.bg.allowsHitTesting(false) }
        .overlay { panelOverlay }
        .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: panel)
        .task(id: loadKey) {
            await loadForCurrentServer()
        }
        .task(id: "\(loadKey)|\(tab.rawValue)") {
            await loadTab()
            openRequestedBot()
        }
        .task(id: router.pendingBotTemplate) {
            openRequestedBot()
        }
        .task(id: recommendationKey) {
            await loadRecommendations()
        }
        .task(id: toolsKey) {
            await loadTools()
        }
        .task(id: toolsKey) {
            await loadOpenJournal()
        }
        .onChange(of: tab) { _, _ in
            query = ""
            panel = nil
            router.marketScroll = nil
        }
        // A pasted `https://bandito.dev/s/<id>` opens the install sheet of that bot or skill, not a search.
        .onChange(of: query) { _, text in
            guard let shareID = ShareLogic.shareID(fromLink: text) else { return }
            query = ""
            router.sheet = .installShared(shareID: shareID)
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
        .onChange(of: app.device.phase) { _, phase in
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
        } message: { integration in
            Text(removeMessage(for: integration))
        }
    }

    /// What the dialog says about removing: a sign-in with a code cannot be taken back from here, so it says where.
    private func removeMessage(for integration: Integration) -> String {
        integration.auth == .device
            ? L10n.Integrations.removeMessage + " " + L10n.Integrations.Device.revokeHint
            : L10n.Integrations.removeMessage
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

    @ViewBuilder
    private var page: some View {
        let supported = server?.supports("integrations") ?? false
        let entries = currentEntries
        if tab == .services, supported, let open = MarketLogic.entry(withID: router.marketDetail, in: entries) {
            detailPage(open)
        } else {
            listPage(supported: supported, entries: entries)
        }
    }

    /// The entries of the catalog and the connected services for the language now, rebuilt only when an input changed.
    private var currentEntries: [MarketEntry] {
        memo.entries(catalog: catalog, integrations: integrations, languageCode: ModelDescription.currentLanguageCode)
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
            },
            tools: toolsInput(for: entry),
            journal: journalInput(for: entry))
    }

    // MARK: - call journal

    private func journalInput(for entry: MarketEntry) -> JournalSectionInput? {
        guard let integration = entry.integration, server?.supports("integrations_calls") == true else { return nil }
        return JournalSectionInput(
            journal: journals[integration.name] ?? CallJournal(),
            loading: journalLoading.contains(integration.name),
            error: journalError,
            agents: server?.agents ?? [],
            server: server,
            onMore: { Task { await loadJournal(integration.name, older: true) } })
    }

    /// Reads a page of the service's calls: the newest, or the one after the rows read.
    private func loadJournal(_ name: String, older: Bool) async {
        guard let server, server.supports("integrations_calls"), !journalLoading.contains(name) else { return }
        let before = older ? journals[name]?.cursor : nil
        if older && before == nil { return }
        journalLoading.insert(name)
        defer { journalLoading.remove(name) }
        do {
            let page = try await server.toolCalls(integration: name, limit: CallJournal.pageSize, before: before)
            guard !Task.isCancelled else { return }
            var journal = journals[name] ?? CallJournal()
            if older { journal.append(page) } else { journal.replace(with: page) }
            journals[name] = journal
            journalError = nil
        } catch {
            guard !Task.isCancelled else { return }
            journalError = UserFacingError.message(for: error)
        }
    }

    /// How much each service was used in the last day; a failed ask leaves the cards without the line.
    private func reloadCallStats(of server: ServerModel) async {
        guard server.supports("integrations_calls") else {
            callStats = [:]
            return
        }
        if let list = try? await server.toolCallStats() {
            callStats = Dictionary(list.map { ($0.integration, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - tool permissions

    /// The "Tools" section of a connected service, when the server can limit tools.
    private func toolsInput(for entry: MarketEntry) -> ToolsSectionInput? {
        guard let integration = entry.integration, server?.supports("tool_permissions") == true else { return nil }
        return ToolsSectionInput(
            tools: toolLists[integration.id] ?? [],
            saving: toolsSaving.contains(integration.id),
            error: toolsError,
            unreached: ToolPermissionLogic.unreachedAgents(server?.agents ?? [], for: integration),
            onMode: { mode in
                guard mode != integration.toolMode else { return }
                Task { await saveTools(integration, IntegrationPatch(toolMode: mode)) }
            },
            onWord: { tool, word in
                let words = ToolPermissionLogic.overrides(
                    setting: word, for: tool, mode: integration.toolMode, current: integration.toolOverrides)
                guard words != integration.toolOverrides else { return }
                Task { await saveTools(integration, IntegrationPatch(toolOverrides: words)) }
            },
            onCheck: { Task { await check(integration.id) } },
            serviceName: entry.name,
            serviceOn: integration.enabled,
            onTry: server?.supports("integrations_call_tool") == true
                ? { tool, arguments in await tryTool(integration, tool, arguments) } : nil)
    }

    /// Runs a tool for the owner and gives back its answer, or the words for why the call did not go through.
    private func tryTool(_ integration: Integration, _ tool: IntegrationTool, _ arguments: JSONValue) async -> ToolTryOutcome {
        guard let server else { return .failure(UserFacingMessage(text: L10n.Failure.noAnswer)) }
        do {
            return .answer(try await server.callTool(integration.id, tool: tool.name, arguments: arguments))
        } catch {
            return .failure(ToolTryFailure.message(for: error))
        }
    }

    /// The open service's id when its page is open on a server that limits tools: what the section is loaded for.
    private var toolsKey: String {
        let open = MarketLogic.entry(withID: router.marketDetail, in: openEntries)?.integration?.id ?? ""
        return "\(loadKey)|\(tab.rawValue)|\(open)"
    }

    private var openEntries: [MarketEntry] { currentEntries }

    private func loadTools() async {
        guard let server, tab == .services, server.supports("tool_permissions"),
            let integration = MarketLogic.entry(withID: router.marketDetail, in: openEntries)?.integration
        else { return }
        await reloadTools(integration.id, from: server)
    }

    /// The journal of the open service, read when its page opens.
    private func loadOpenJournal() async {
        guard let server, tab == .services, server.supports("integrations_calls"),
            let name = MarketLogic.entry(withID: router.marketDetail, in: openEntries)?.integration?.name
        else { return }
        await loadJournal(name, older: false)
    }

    private func reloadTools(_ id: String, from server: ServerModel) async {
        do {
            let list = try await server.integrationTools(id)
            guard !Task.isCancelled else { return }
            toolLists[id] = list
            toolsError = nil
        } catch {
            // A daemon that does not list tools yet leaves the section with its "check the service" line.
            guard !Task.isCancelled else { return }
            toolLists[id] = toolLists[id] ?? []
        }
    }

    /// Saves the mode or the words of one service. The controls wait for the answer; the list is read again.
    private func saveTools(_ integration: Integration, _ patch: IntegrationPatch) async {
        guard let server, !toolsSaving.contains(integration.id) else { return }
        toolsSaving.insert(integration.id)
        defer { toolsSaving.remove(integration.id) }
        do {
            try await server.updateIntegration(integration.id, patch: patch)
            toolsError = nil
            await reload()
        } catch {
            toolsError = UserFacingError.message(for: error)
        }
    }

    private func listPage(supported: Bool, entries: [MarketEntry]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(supported: supported)
                .padding(.horizontal, MarketGridLayout.sidePadding)
            scrollArea(supported: supported, entries: entries)
        }
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The scroll view of the page. It spans the window, so a hover shadow or the pinned header is never cut at the
    /// page margin; the margin is inside the content. The columns come from its width.
    private func scrollArea(supported: Bool, entries: [MarketEntry]) -> some View {
        let content: MarketContent? =
            tab == .services && supported
            ? memo.content(entries, filter: router.marketFilter, query: query) : nil
        let sections: [MarketSection] = {
            if case .sections(let list) = content { return list }
            return []
        }()
        let recommendation = tab == .services && supported ? recommendationContext : nil
        let firstIsConnected = sections.first?.kind == .connected
        tracker.configure(ids: sections.map(\.id))
        let context = MarketScrollContext(
            sections: sections, tracker: tracker, ready: !sections.isEmpty,
            request: router.marketScroll,
            onHandled: { router.marketScroll = nil },
            onActive: { index in
                let name = index.flatMap { sections.indices.contains($0) ? sections[$0].categoryName : nil }
                if router.marketSection != name { router.marketSection = name }
            })
        return ScrollViewReader { proxy in
            ScrollView {
                if let content {
                    servicesContent(
                        content, recommendation: recommendation, firstIsConnected: firstIsConnected,
                        onActive: context.onActive)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        if tab == .bots {
                            botsContent
                        } else if tab == .skills {
                            skillsContent
                        } else {
                            ServerUnavailable(server: server)
                        }
                    }
                    .padding(.horizontal, MarketGridLayout.sidePadding)
                    .padding(.top, MarketSectionMetrics.topInset)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .scrollIndicators(.automatic)
            .environment(\.marketColumns, columns)
            .onGeometryChange(for: Int.self) { MarketGridLayout.columns(scrollWidth: $0.size.width) } action: { new in
                if columns != new { columns = new }
            }
            .onGeometryChange(for: CGFloat.self) { ($0.size.height / 8).rounded() * 8 } action: { new in
                if viewportHeight != new { viewportHeight = new }
            }
            .modifier(MarketScrollDriver(context: context, proxy: proxy))
        }
        .onChange(of: router.marketScroll) { _, request in
            // A jump to a block needs the blocks: a search is cleared first.
            if request != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query = "" }
        }
        .task(id: tileWarmKey) { await warmTiles(entries) }
    }

    /// The Services page. Under All: pinned blocks (the connected services, then the categories). A search, or the
    /// Connected filter: one flat list.
    @ViewBuilder
    private func servicesContent(
        _ content: MarketContent, recommendation: RecommendationContext?, firstIsConnected: Bool,
        onActive: @escaping (Int?) -> Void
    ) -> some View {
        let actions = cardActions
        // Not a lazy stack: it does not know the height of what it has not built, so a jump upward landed in the wrong
        // place. A page of about eight blocks and sixty light, Equatable cards is cheap to build once.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: MarketSectionMetrics.topInset)
                .id(MarketScrollDriver.topID)
            switch content {
            case .sections(let sections):
                if let recommendation, !firstIsConnected {
                    recommendationRow(recommendation)
                        .padding(.horizontal, MarketGridLayout.sidePadding)
                        .padding(.bottom, 14)
                }
                ForEach(Array(sections.enumerated()), id: \.element.scrollID) { index, section in
                    VStack(alignment: .leading, spacing: 0) {
                        // The place of the header; the header itself is drawn over it and stays at the top.
                        Color.clear.frame(height: MarketSectionMetrics.headerHeight)
                        sectionBody(
                            section, actions: actions,
                            recommendation: section.kind == .connected ? recommendation : nil)
                        Color.clear.frame(height: MarketSectionMetrics.sectionGap)
                    }
                    .overlay {
                        MarketStickyHeader(
                            title: title(of: section), count: section.entries.count, tone: .of(section))
                    }
                    .id(section.scrollID)
                    .marketAnchor { y in
                        if tracker.report(index: index, minY: y) { onActive(tracker.active) }
                    }
                }
                if let last = sections.last {
                    Color.clear.frame(
                        height: MarketSectionMetrics.bottomPadding(
                            viewport: viewportHeight,
                            last: last.kind == .connected
                                ? viewportHeight : MarketSectionMetrics.height(cards: last.entries.count, columns: columns)))
                }
            case .flat(let items, let empty):
                MarketRowList(
                    items: items, columns: columns, rowHeight: MarketSectionMetrics.cardHeight,
                    inset: MarketGridLayout.sidePadding
                ) { entry in
                    MarketCatalogCard(entry: entry, actions: actions).equatable()
                }
                if let empty {
                    emptyText(empty)
                        .padding(.horizontal, MarketGridLayout.sidePadding)
                }
                Color.clear.frame(height: 24)
                    .onAppear { if router.marketSection != nil { router.marketSection = nil } }
            }
            if let error {
                UserFacingErrorView(message: error)
                    .padding(.horizontal, MarketGridLayout.sidePadding)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            tracker.reset()
            if case .sections = content, router.marketSection != nil { router.marketSection = nil }
        }
    }

    /// The cards of a block: the connected services as full cards, the catalog as even cards of one height.
    @ViewBuilder
    private func sectionBody(
        _ section: MarketSection, actions: MarketCardActions, recommendation: RecommendationContext?
    ) -> some View {
        if section.kind == .connected {
            VStack(alignment: .leading, spacing: 0) {
                MarketRowList(
                    items: section.entries, columns: columns, rowHeight: nil, inset: MarketGridLayout.sidePadding
                ) { entry in
                    connectedCard(entry, actions: actions)
                }
                if let recommendation {
                    recommendationRow(recommendation)
                        .padding(.horizontal, MarketGridLayout.sidePadding)
                        .padding(.bottom, 14)
                }
            }
        } else {
            MarketRowList(
                items: section.entries, columns: columns, rowHeight: MarketSectionMetrics.cardHeight,
                inset: MarketGridLayout.sidePadding
            ) { entry in
                MarketCatalogCard(entry: entry, actions: actions).equatable()
            }
        }
    }

    @ViewBuilder
    private func connectedCard(_ entry: MarketEntry, actions: MarketCardActions) -> some View {
        if let integration = entry.integration {
            MarketConnectedCard(
                entry: entry, integration: integration,
                status: IntegrationStatus.of(integration, test: tests[integration.id], connection: connections[integration.id]),
                statsLine: CallJournalText.statsLine(callStats[integration.name]),
                updating: updating.contains(integration.id), checking: checking.contains(integration.id),
                actions: actions
            )
            .equatable()
        }
    }

    private func title(of section: MarketSection) -> String {
        switch section.kind {
        case .connected: L10n.Integrations.connected
        case .category(let name): MarketCategory.title(name)
        case .catalog: L10n.Integrations.catalog
        }
    }

    /// What the cards ask of the page.
    private var cardActions: MarketCardActions {
        MarketCardActions(
            open: { router.marketDetail = $0.id },
            connect: { connect($0) },
            configure: { editing = .edit($0) },
            check: { integration in Task { await check(integration.id) } },
            remove: { removing = $0 },
            signInAgain: { signInAgain($0) },
            setEnabled: { integration, on in Task { await setEnabled(integration, on) } },
            update: { integration in Task { await updateFromTemplate(integration) } })
    }

    /// Changes when the set of tiles to draw changes.
    private var tileWarmKey: String {
        "\(catalog.count)|\(integrations.count)|\(tab.rawValue)"
    }

    /// Draws the tiles of the Services page ahead of the scroll, a few at a time, so the first fast scroll finds them
    /// ready. They are bitmaps afterwards (see `MarketTileImages`).
    private func warmTiles(_ entries: [MarketEntry]) async {
        guard tab == .services else { return }
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { return }
            MarketTile(entry: entry, size: 36).prime()
            if entry.isConnected { MarketTile(entry: entry, size: 32).prime() }
            if index % 4 == 3 { await Task.yield() }
        }
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if tabs.count == 1, supported {
                    // A server with only services keeps the one-row header.
                    headerActions(showsSearch: true, addsIntegration: true)
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
                    headerActions(
                        showsSearch: tab != .services || supported,
                        addsIntegration: tab == .services && supported)
                }
            }
        }
    }

    /// The search field and the actions of the header: text buttons, icon buttons or one menu, whichever fits.
    private func headerActions(showsSearch: Bool, addsIntegration: Bool) -> some View {
        MarketHeaderActions(
            showsSearch: showsSearch,
            search: searchField,
            addsIntegration: addsIntegration,
            showsMine: sharingSupported,
            onImport: { router.sheet = .importer },
            onOwn: { editing = .custom },
            onMine: { router.sheet = .myShares })
    }

    private var subtitle: String {
        switch tab {
        case .services: L10n.Market.subtitle
        case .bots: L10n.Market.Bots.subtitle
        case .skills: L10n.Market.Skills.subtitle
        }
    }

    /// The server has the `sharing` feature: bots and skills can be published, and the list of one's shares exists.
    private var sharingSupported: Bool {
        server?.supports("sharing") ?? false
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
            agents: server?.agents ?? [], canShare: sharingSupported,
            onView: { panel = .botDetail($0.id) },
            onCreate: { panel = .botCreate($0.id) },
            onViewBundle: { panel = .bundle($0.id) },
            onOpen: { agent in
                guard let server else { return }
                router.selectAgent(agent.id, on: server)
                router.select(mode: .team)
            },
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
            onUpdate: { skill in Task { await updateSkill(skill, targets: SkillLogic.updateTargets(skill)) } },
            onRetry: { if let server { Task { await skills.load(from: server) } } },
            onShare: { skill in router.sheet = .share(.skill(name: skill.name)) })
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
            case .bundle(let id):
                if let bundle = bots.bundles.first(where: { $0.id == id }) {
                    MarketPanel(width: 580, canClose: !panelBusy, onClose: closePanel) {
                        BundlePanel(
                            bundle: bundle, members: BundleLogic.members(of: bundle, templates: bots.templates),
                            services: BundleLogic.services(
                                of: bundle, templates: bots.templates, catalog: catalog, integrations: integrations),
                            server: server, languageCode: languageCode, creating: $panelBusy,
                            onClose: closePanel, onConnect: { connect($0) })
                        .id(bundle.id)
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
                            },
                            onUpdate: { target in Task { await updateSkill(skill, targets: [target]) } })
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

    /// The Team home asked for a bot's create panel: it opens once the Bots page has the templates. The request is
    /// taken once; a template the catalog does not list is dropped.
    private func openRequestedBot() {
        guard tab == .bots, server == nil || bots.loaded || bots.failure != nil,
            let id = router.takePendingBotTemplate()
        else { return }
        guard server != nil, bots.templates.contains(where: { $0.id == id }) else { return }
        panel = .botCreate(id)
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

    // MARK: - actions

    /// Clears what belongs to the previous server, then loads the current one.
    private func loadForCurrentServer() async {
        let id = server?.id
        if id != shownServer {
            shownServer = id
            integrations = []
            catalog = []
            router.marketCategories = []
            router.marketSection = nil
            router.marketScroll = nil
            router.marketDetail = nil
            router.marketBotCategories = []
            router.marketSkillCategories = []
            router.marketBotFilter = .all
            router.marketSkillFilter = .all
            bots.reset()
            skills.reset()
            recommendations = []
            updating = []
            toolLists = [:]
            toolsSaving = []
            toolsError = nil
            callStats = [:]
            journals = [:]
            journalLoading = []
            journalError = nil
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
            await reloadCallStats(of: server)
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

    /// Connect: a service that signs in with a code shows the code, one that signs in in the browser opens it; the
    /// others open the sheet of keys.
    private func connect(_ template: IntegrationCatalogEntry) {
        if template.usesDevice, let url = template.url {
            connectWithCode(template, url: url)
            return
        }
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
        Task { await app.oauth.begin(server: server, target: .draft(draft), name: template.name, catalogID: template.id) }
    }

    /// Connect for a service that signs in with a code. A daemon without the feature says to update.
    private func connectWithCode(_ template: IntegrationCatalogEntry, url: String) {
        guard let server else { return }
        guard server.supports("integrations_device") else {
            error = UserFacingMessage(text: L10n.Integrations.Device.needsUpdate(name: template.name))
            return
        }
        let draft = NewIntegration(name: template.id, kind: .http, url: url)
        Task { await app.device.begin(server: server, target: .draft(draft), name: template.name, catalogID: template.id) }
    }

    private func signInAgain(_ integration: Integration) {
        guard let server else { return }
        // The name the card shows: a service's name, or the owner's own name for an own integration.
        let entry = MarketLogic.entries(catalog: catalog, integrations: integrations, languageCode: "en")
            .first { $0.integration?.id == integration.id }
        if integration.auth == .device {
            Task {
                await app.device.begin(
                    server: server, target: .existing(id: integration.id), name: entry?.name ?? integration.name)
            }
            return
        }
        Task { await app.oauth.begin(server: server, target: .existing(id: integration.id), name: entry?.name ?? integration.name) }
    }

    /// A sign-in just ended well: the list is read again and the new service is checked, so its tools show.
    private func signedIn(_ id: String) async {
        await reload()
        await check(id)
    }

    /// Brings a connected service up to its catalog template. The last check no longer says anything about the new
    /// definition, so it is dropped; the list is read again.
    private func updateFromTemplate(_ integration: Integration) async {
        guard let server, !updating.contains(integration.id) else { return }
        updating.insert(integration.id)
        defer { updating.remove(integration.id) }
        do {
            try await server.updateIntegrationFromTemplate(integration.id)
            tests[integration.id] = nil
            await reload()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    /// Updates a skill in each place it is behind: the same install, in the same scope.
    private func updateSkill(_ skill: SkillEntry, targets: [SkillLogic.Target]) async {
        guard let server else { return }
        for target in targets {
            if let failure = await skills.change(skill.id, target: target, install: true, on: server) {
                error = SkillText.message(for: failure)
                return
            }
        }
        error = nil
    }

    // MARK: - suggestions

    /// The agent the row of suggestions is for, when the server can suggest and there is one.
    private var recommendationAgent: Agent? {
        guard tab == .services, let server, server.supports("integrations"), server.supports("integrations_recommend")
        else { return nil }
        return RecommendationLogic.agent(
            selected: router.selectedAgentID, remembered: LastOpenedAgent.load(serverID: server.id.uuidString),
            agents: server.agents)
    }

    /// Asks again when the server, the agent or the connected services change (a connected service leaves the list).
    private var recommendationKey: String {
        "\(loadKey)|\(recommendationAgent?.id ?? "")|\(integrations.map(\.id).joined(separator: ","))"
    }

    private func isRecommendationHidden(_ agent: Agent) -> Bool {
        _ = hideTick
        guard let server else { return true }
        return RecommendationStore.isHidden(server: server.id.uuidString, agent: agent.id)
    }

    private func loadRecommendations() async {
        guard let server, let agent = recommendationAgent, !isRecommendationHidden(agent) else {
            if !recommendations.isEmpty { recommendations = [] }
            return
        }
        do {
            let list = try await server.recommendedIntegrations(agentID: agent.id)
            guard !Task.isCancelled, recommendationAgent?.id == agent.id else { return }
            recommendations = list
        } catch {
            // The row is a hint: a failed ask just leaves it out.
            guard !Task.isCancelled else { return }
            recommendations = []
        }
    }

    /// The row of suggestions when it is to be shown: under All, with no search, for an agent that has suggestions.
    struct RecommendationContext {
        let serverID: String
        let agent: Agent
        let items: [RecommendationLogic.Item]
    }

    var recommendationContext: RecommendationContext? {
        guard router.marketFilter == .all, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let server, let agent = recommendationAgent, !isRecommendationHidden(agent)
        else { return nil }
        let items = RecommendationLogic.items(recommendations, catalog: catalog, integrations: integrations)
        return items.isEmpty ? nil : RecommendationContext(serverID: server.id.uuidString, agent: agent, items: items)
    }

    /// "Suited to <agent>'s project": up to six services, shown over the catalog under All with no search.
    func recommendationRow(_ context: RecommendationContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(L10n.Market.Recommend.title(agent: context.agent.name))
                Spacer(minLength: 8)
                Button {
                    RecommendationStore.hide(server: context.serverID, agent: context.agent.id)
                    hideTick += 1
                } label: {
                    Image(systemName: "xmark")
                }
                .banditoButton(.icon(size: 24, label: L10n.Market.Recommend.hide))
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(context.items) { item in
                        RecommendationCard(item: item, onConnect: { connect(item.template) })
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
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
            if server.supports("tool_permissions") { await reloadTools(id, from: server) }
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

/// The surface of a Marketplace card: the Bandito surface with a hairline border. Under the pointer the border gets
/// lighter, the card lifts 1.5 pt and floats on a shadow; the shadow exists only while that one card is hovered (a
/// shadow on every card of a long list was redrawn on every scroll step). The card fills the height its row gives it,
/// so cards of a row are even.
struct MarketCardFrame<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                if hovering {
                    shape.fill(Color.Bandito.surface1).shadow(color: .black.opacity(0.22), radius: 12, y: 7)
                } else {
                    shape.fill(Color.Bandito.surface1)
                }
            }
            .overlay(shape.strokeBorder(hovering ? Color.Bandito.text.opacity(0.22) : Color.Bandito.line, lineWidth: 1))
            .contentShape(shape)
            .offset(y: hovering ? -1.5 : 0)
            .onHover { inside in
                if hovering != inside { hovering = inside }
            }
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: hovering)
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

    /// A short word for the colour `color(hex:name:)` gives: the accent, or the palette index. Part of a tile's cache key.
    static func colorKey(hex: String?, name: String) -> String {
        if let value = hex.flatMap(AvatarHex.value) { return String(value, radix: 16) }
        return "p\(paletteIndex(for: name))"
    }

    static func colorKey(of entry: MarketEntry) -> String {
        if let hex = accent(of: entry) { return String(hex, radix: 16) }
        return "p\(paletteIndex(for: entry.name))"
    }
}

/// The tile of a Marketplace entry: a rounded square in the service's colour with a soft vertical gradient (lighter on
/// top), a thin highlight on the upper edge, and a white symbol, or the first letter of the name for an own
/// integration. With `glow` it casts a soft shadow of its colour. Without `glow` the tile is drawn once and kept as a
/// picture (see `MarketTileImages`).
struct MarketTile: View {
    let entry: MarketEntry
    let size: CGFloat
    var glow = false

    /// Everything that changes how the tile looks.
    private var cacheKey: String {
        let template = entry.template
        return "svc|\(template?.id ?? "-")|\(MarketTileStyle.colorKey(of: entry))|\(template?.icon ?? "")|"
            + "\(template?.kind == .http ? "h" : "s")|\(template == nil ? String(entry.name.prefix(1)) : "")"
    }

    private var surface: MarketTileSurface<some View> {
        MarketTileSurface(
            color: MarketTileStyle.color(of: entry), size: size, glow: glow, cacheKey: cacheKey
        ) { glyph }
    }

    var body: some View { surface }

    /// Draws the picture into the cache now, if it is not there.
    func prime() { surface.prime() }

    @ViewBuilder
    private var glyph: some View {
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

/// The look of every Marketplace tile (a service, a bot, a skill): a rounded square in one colour with a soft vertical
/// gradient (lighter on top), a thin highlight on the upper edge, and a white symbol. With `glow` it casts a soft
/// shadow of its colour. With a `cacheKey` (and no glow) the tile is rendered once to a bitmap and drawn from it: the
/// key must name everything that shapes the tile except its size.
struct MarketTileSurface<Content: View>: View {
    let color: Color
    let size: CGFloat
    var glow = false
    var cacheKey: String?
    @ViewBuilder var content: Content

    var body: some View {
        if let picture = cachedPicture {
            Image(nsImage: picture)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            MarketTileFace(color: color, size: size, glow: glow) { content }
        }
    }

    private var cachedPicture: NSImage? {
        guard let cacheKey, !glow else { return nil }
        return MarketTileImages.shared.image(key: "\(cacheKey)|\(size)") {
            MarketTileFace(color: color, size: size, glow: false) { content }
        }
    }

    /// Fills the cache for this tile.
    func prime() { _ = cachedPicture }
}

/// The tile as it is drawn: the gradient, the highlight, the glyph and its small shadow.
struct MarketTileFace<Content: View>: View {
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
            .modifier(TileGlow(color: color, active: glow))
    }
}

/// The soft shadow of a glowing tile; a tile without glow has no shadow modifier at all.
private struct TileGlow: ViewModifier {
    let color: Color
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.shadow(color: color.opacity(0.35), radius: 16, y: 6)
        } else {
            content
        }
    }
}

/// Builds the entries and the page only when an input changed. The page body runs on every state change (a hover on
/// the header, a check result, a scroll block), and `MarketLogic.entries` compares every integration with every
/// template, URLs included: that work belongs outside the body.
@MainActor
final class MarketListMemo {
    private struct EntriesKey: Equatable {
        let catalog: [IntegrationCatalogEntry]
        let integrations: [Integration]
        let languageCode: String
    }

    private struct ContentKey: Equatable {
        let entries: [MarketEntry]
        let filter: MarketFilter
        let query: String
    }

    private var entriesKey: EntriesKey?
    private var entriesValue: [MarketEntry] = []
    private var contentKey: ContentKey?
    private var contentValue: MarketContent = .sections([])

    func entries(catalog: [IntegrationCatalogEntry], integrations: [Integration], languageCode: String) -> [MarketEntry] {
        let key = EntriesKey(catalog: catalog, integrations: integrations, languageCode: languageCode)
        if key != entriesKey {
            entriesValue = MarketLogic.entries(catalog: catalog, integrations: integrations, languageCode: languageCode)
            entriesKey = key
        }
        return entriesValue
    }

    func content(_ entries: [MarketEntry], filter: MarketFilter, query: String) -> MarketContent {
        let key = ContentKey(entries: entries, filter: filter, query: query)
        if key != contentKey {
            contentValue = MarketSections.content(entries, filter: filter, query: query)
            contentKey = key
        }
        return contentValue
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
/// `Router` and leaves the page of a service. On the Services page All and the categories do not filter: the page is
/// one list of blocks, and they scroll it; the row of the block in view is lit, and each category has the color of its
/// block.
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
        case .services:
            MarketSidebarLogic.highlighted(
                tab: tab, filter: router.marketFilter, section: router.marketDetail == nil ? router.marketSection : nil)
        case .bots: router.marketBotFilter
        case .skills: router.marketSkillFilter
        }
    }

    private func choose(_ filter: MarketFilter) {
        switch MarketSidebarLogic.action(for: filter, tab: tab) {
        case .filter(let picked):
            switch tab {
            case .services: router.marketFilter = picked
            case .bots: router.marketBotFilter = picked
            case .skills: router.marketSkillFilter = picked
            }
            router.marketSection = nil
        case .scroll(let target):
            if router.marketFilter != .all { router.marketFilter = .all }
            router.requestMarketScroll(target)
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
                    HStack(spacing: 8) {
                        if tab == .services, let tone = dotTone(filter) {
                            Circle()
                                .fill(tone.color)
                                .frame(width: 7, height: 7)
                                .opacity(selected ? 1 : 0.7)
                                .accessibilityHidden(true)
                        }
                        Text(filter.title)
                            .font(BanditoFont.text(size: 13, weight: selected ? 600 : 400))
                            .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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

    /// The color of a Services row: a category has its block's color, Connected has the "working" green.
    private func dotTone(_ filter: MarketFilter) -> MarketTone? {
        switch filter {
        case .connected: .connected
        case .category(let name): .of(category: name)
        default: nil
        }
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
