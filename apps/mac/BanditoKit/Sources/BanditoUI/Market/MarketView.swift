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
    /// The server the lists above belong to. A switch to another server clears them before the new lists load.
    @State private var shownServer: UUID?
    @State private var query = ""
    @State private var error: UserFacingMessage?
    @State private var editing: IntegrationTarget?
    @State private var removing: Integration?

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
        .task(id: loadKey) {
            await loadForCurrentServer()
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

    private var page: some View {
        let supported = server?.supports("integrations") ?? false
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: integrations, languageCode: ModelDescription.currentLanguageCode)
        let shown = MarketLogic.page(entries, filter: router.marketFilter, query: query)
        let empty = MarketLogic.emptyState(shown, filter: router.marketFilter, query: query)
        if supported, let open = MarketLogic.entry(withID: router.marketDetail, in: entries) {
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
            onBack: { router.marketDetail = nil },
            onConnect: { if let template = entry.template { editing = .catalog(template) } },
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
                    if supported {
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
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.Mode.market)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Market.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if supported {
                searchField
                Button(L10n.Integrations.addOwn) { editing = .custom }
                    .banditoButton(.quiet())
                    .fixedSize()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.Market.search, text: $query)
                .banditoField()
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text)
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.Bandito.line))
    }

    private func emptyText(_ state: MarketEmptyState) -> some View {
        Text(state == .noResults ? L10n.Market.noResults : L10n.Integrations.empty)
            .font(.system(size: 13))
            .foregroundStyle(Color.Bandito.text3)
            .padding(.vertical, 6)
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
        let status = IntegrationStatus.of(integration, test: tests[integration.id])
        return MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    MarketTile(entry: entry, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(integration.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(MarketLogic.address(integration))
                            .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    menu(integration)
                }
                statusLine(status)
                Toggle(isOn: Binding(get: { integration.enabled }, set: { on in
                    Task { await setEnabled(integration, on) }
                })) {
                    Text(L10n.Market.availableToAgents)
                        .font(.system(size: 12.5))
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
            Button(L10n.Integrations.edit) { editing = .edit(integration) }
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        if let publisher = entry.template?.publisher {
                            Text(publisher)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.description)
                    .font(.system(size: 12.5))
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
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.Bandito.ok)
            Button(L10n.Market.configure) { editing = .edit(integration) }
                .banditoButton(.link)
                .fixedSize()
        } else if let template = entry.template {
            Button(L10n.Integrations.connect) { editing = .catalog(template) }
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
            tests = [:]
            checking = []
            error = nil
        }
        await reload()
    }

    private func reload() async {
        guard let server, server.info != nil, server.supports("integrations") else { return }
        do {
            integrations = try await server.integrations()
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
            tests[id] = try await server.testIntegration(id)
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
private struct MarketCardFrame<Content: View>: View {
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
        let base = MarketTileStyle.color(of: entry)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            if let template = entry.template {
                Image(systemName: IntegrationSymbol.name(icon: template.icon, kind: template.kind))
                    .font(.system(size: size * 0.44, weight: .semibold))
            } else {
                Text(String(entry.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        .frame(width: size, height: size)
        .background(
            shape.fill(base).overlay(
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .clear, .black.opacity(0.14)],
                        startPoint: .top, endPoint: .bottom))))
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
        .shadow(color: glow ? base.opacity(0.35) : .clear, radius: 16, y: 6)
    }
}

/// The result of the last check of an integration, in one line.
struct IntegrationStatusLine: View {
    let status: IntegrationStatus

    var body: some View {
        switch status {
        case .disabled:
            Text(L10n.Integrations.Status.disabled)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
        case .unchecked:
            Text(L10n.Integrations.Status.unchecked)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
        case .connected(let tools):
            Label {
                Text(L10n.Integrations.Status.connected(count: tools))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.Bandito.ok)
        case .failed(let failure):
            Label {
                Text(IntegrationFailureText.text(failure))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.Bandito.danger)
        }
    }
}

/// Sidebar of the Marketplace: All, Connected, and the categories of the catalog. Picking one sets
/// `Router.marketFilter` and leaves the page of a service.
struct MarketSidebar: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MarketFilter.rows(categories: router.marketCategories)) { filter in
                let selected = router.marketFilter == filter
                if case .category(let name) = filter, name == router.marketCategories.first {
                    Divider().padding(.vertical, 6).padding(.horizontal, 10)
                }
                Button {
                    router.marketFilter = filter
                    router.marketDetail = nil
                } label: {
                    Text(filter.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
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
