import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Integrations: the MCP servers the agents may use, and the catalog to connect more from.
struct IntegrationsView: View {
    let server: ServerModel?
    @State private var integrations: [Integration] = []
    @State private var catalog: [IntegrationCatalogEntry] = []
    /// The last check of each integration in this session. The daemon keeps no check result.
    @State private var tests: [String: IntegrationTest] = [:]
    @State private var checking: Set<String> = []
    @State private var error: UserFacingMessage?
    @State private var editing: IntegrationTarget?
    @State private var removing: Integration?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 12, alignment: .top)]

    var body: some View {
        ServerPage(
            title: L10n.Mode.serverIntegrations,
            trailing: {
                if let server, server.supports("integrations") {
                    Button(L10n.Integrations.addOwn) { editing = .custom }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
            }
        ) {
            if let server, server.supports("integrations") {
                Text(L10n.Integrations.hint)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                if integrations.isEmpty {
                    Text(L10n.Integrations.empty)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.vertical, 6)
                } else {
                    SectionLabel(L10n.Integrations.connected)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(integrations) { integration in
                            connectedCard(integration)
                        }
                    }
                }
                if !offered.isEmpty {
                    SectionLabel(L10n.Integrations.catalog)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(offered, id: \.id) { entry in
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
        .task(id: server?.info != nil) {
            await reload()
        }
        .banditoSheet(item: $editing) { target in
            if let server {
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

    /// The catalog entries that are not connected yet: a template whose name is taken is already there.
    private var offered: [IntegrationCatalogEntry] {
        catalog.filter { entry in !integrations.contains { $0.name == entry.id } }
    }

    // MARK: - cards

    private func connectedCard(_ integration: Integration) -> some View {
        let status = IntegrationStatus.of(integration, test: tests[integration.id])
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IntegrationIconTile(symbol: IntegrationSymbol.name(icon: catalog.first { $0.id == integration.name }?.icon, kind: integration.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(integration.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(Self.detail(integration))
                        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: Binding(get: { integration.enabled }, set: { on in
                    Task { await setEnabled(integration, on) }
                })) {
                    EmptyView()
                }
                .toggleStyle(BanditoToggleStyle())
                .labelsHidden()
                .help(L10n.Integrations.toggleHelp)
            }
            statusLine(status, integrationID: integration.id)
            HStack(spacing: 8) {
                let isChecking = checking.contains(integration.id)
                Button(isChecking ? L10n.Integrations.checking : L10n.Integrations.check) {
                    Task { await check(integration.id) }
                }
                .banditoButton(.quiet())
                .disabled(isChecking || !integration.enabled)
                .fixedSize()
                Spacer(minLength: 8)
                Menu {
                    Button(L10n.Integrations.edit) { editing = .edit(integration) }
                    Button(L10n.Integrations.remove, role: .destructive) { removing = integration }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .banditoButton(.icon(size: 26, label: L10n.Integrations.more))
                .help(L10n.Integrations.more)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    private func catalogCard(_ entry: IntegrationCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IntegrationIconTile(symbol: IntegrationSymbol.name(icon: entry.icon, kind: entry.kind))
                Text(entry.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            Text(entry.description(languageCode: ModelDescription.currentLanguageCode))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer(minLength: 8)
                Button(L10n.Integrations.connect) {
                    editing = .catalog(entry)
                }
                .banditoButton(.signal())
                .fixedSize()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    @ViewBuilder
    private func statusLine(_ status: IntegrationStatus, integrationID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .disabled:
                Text(L10n.Integrations.Status.disabled)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
            case .unchecked:
                Text(L10n.Integrations.Status.unchecked)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
            case .connected(let count):
                Label {
                    Text(L10n.Integrations.Status.connected(count: count))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.Bandito.ok)
                if let names = tests[integrationID]?.tools, !names.isEmpty {
                    Text(L10n.Integrations.toolsFound(names: names.joined(separator: ", ")))
                        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(2)
                }
            case .failed(let failure):
                Label {
                    Text(L10n.Integrations.Status.failed)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.Bandito.danger)
                Text(IntegrationFailureText.text(failure))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `https://…` for a web integration; the command and its arguments for a program.
    static func detail(_ integration: Integration) -> String {
        switch integration.kind {
        case .http:
            return integration.url ?? ""
        case .stdio:
            return ([integration.command ?? ""] + integration.args).joined(separator: " ")
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

/// The 32 pt tile with the symbol of an integration.
struct IntegrationIconTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.Bandito.info)
            .frame(width: 32, height: 32)
            .background(Color.Bandito.info.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
