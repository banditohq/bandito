import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Marketplace mode: the services the agents can use. The connected ones come first, then the catalog to connect
/// more from. Connecting, configuring and removing happen here; the sidebar picks the filter.
struct MarketView: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app

    @State private var integrations: [Integration] = []
    @State private var catalog: [IntegrationCatalogEntry] = []
    /// The last check of each integration in this session. The daemon keeps no check result.
    @State private var tests: [String: IntegrationTest] = [:]
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
        .task(id: app.currentServer?.info != nil) {
            await reload()
        }
        .banditoSheet(item: $editing) { target in
            if let server = app.currentServer {
                IntegrationEditor(
                    server: server, target: target, existingNames: integrations.map(\.name),
                    onChecked: { id, result in tests[id] = result },
                    onSaved: { await reload() })
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

    private var page: some View {
        let supported = server?.supports("integrations") ?? false
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: integrations, languageCode: ModelDescription.currentLanguageCode)
        let shown = MarketLogic.page(entries, filter: router.marketFilter, query: query)
        return VStack(alignment: .leading, spacing: 16) {
            header(supported: supported)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if supported {
                        if !shown.connected.isEmpty {
                            SectionLabel(L10n.Integrations.connected)
                            connectedRow(shown.connected)
                            SectionLabel(L10n.Integrations.catalog)
                        }
                        if shown.grid.isEmpty {
                            emptyText
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(shown.grid) { entry in
                                    catalogCard(entry)
                                }
                            }
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
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text)
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.Bandito.line))
    }

    /// Shown when the grid is empty: a search with no match says so; the Connected filter with nothing connected says
    /// how to connect.
    @ViewBuilder
    private var emptyText: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        Text(searching ? L10n.Market.noResults : L10n.Integrations.empty)
            .font(.system(size: 13))
            .foregroundStyle(Color.Bandito.text3)
            .padding(.vertical, 6)
    }

    // MARK: - cards

    /// The connected services as compact cards in one row: a click opens the settings, the menu turns it on or off,
    /// edits it or removes it.
    private func connectedRow(_ entries: [MarketEntry]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
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
        return Button {
            editing = .edit(integration)
        } label: {
            MarketCardFrame {
                HStack(spacing: 10) {
                    MarketTile(entry: entry, size: 28)
                    Text(integration.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    statusDot(status)
                }
                .padding(.horizontal, 12)
                .frame(width: 230, height: 54)
            }
        }
        .banditoButton(.row(cornerRadius: 14))
        .contextMenu {
            Toggle(L10n.Market.availableToAgents, isOn: Binding(get: { integration.enabled }, set: { on in
                Task { await setEnabled(integration, on) }
            }))
            Button(L10n.Integrations.edit) { editing = .edit(integration) }
            Divider()
            Button(L10n.Integrations.remove, role: .destructive) { removing = integration }
        }
    }

    private func catalogCard(_ entry: MarketEntry) -> some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MarketTile(entry: entry, size: 36)
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(entry.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    cardActions(entry)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        }
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

    private func statusDot(_ status: IntegrationStatus) -> some View {
        Circle()
            .fill(Self.statusColor(status))
            .frame(width: 8, height: 8)
            .help(Self.statusText(status))
            .accessibilityLabel(Self.statusText(status))
    }

    static func statusColor(_ status: IntegrationStatus) -> Color {
        switch status {
        case .connected: Color.Bandito.ok
        case .failed: Color.Bandito.danger
        case .unchecked, .disabled: Color.Bandito.text3
        }
    }

    static func statusText(_ status: IntegrationStatus) -> String {
        switch status {
        case .disabled: L10n.Integrations.Status.disabled
        case .unchecked: L10n.Integrations.Status.unchecked
        case .connected(let tools): L10n.Integrations.Status.connected(count: tools)
        case .failed: L10n.Integrations.Status.failed
        }
    }

    // MARK: - actions

    private func reload() async {
        guard let server, server.info != nil, server.supports("integrations") else { return }
        do {
            integrations = try await server.integrations()
            if catalog.isEmpty {
                catalog = try await server.integrationCatalog()
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
            .onHover { hovering = $0 }
            .banditoAnimation(.easeOut(duration: BanditoMotion.base), value: hovering)
    }
}

/// The 36 pt (or smaller) tile of a Marketplace entry: the symbol of its catalog icon, or the first letter of its
/// name when it has no catalog entry (an own integration).
private struct MarketTile: View {
    let entry: MarketEntry
    let size: CGFloat

    var body: some View {
        Group {
            if let template = entry.template {
                Image(systemName: IntegrationSymbol.name(icon: template.icon, kind: template.kind))
                    .font(.system(size: size * 0.42, weight: .medium))
            } else {
                Text(String(entry.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(Color.Bandito.info)
        .frame(width: size, height: size)
        .background(Color.Bandito.info.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Sidebar of the Marketplace: the two filters. Picking one sets `Router.marketFilter`.
struct MarketSidebar: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MarketFilter.allCases) { filter in
                let selected = router.marketFilter == filter
                Button {
                    router.marketFilter = filter
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
        default: kind == .http ? "network" : "puzzlepiece.extension"
        }
    }
}
