import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// The bundles on the Bots page: the row of sets, a set's card, and the panel that shows what a set holds, connects
// what it needs, and makes the team. The panel ends with what was made, and opens the first bot.

/// A tile with a set's SF Symbol on its accent colour.
struct BundleTile: View {
    let bundle: AgentBundle
    let size: CGFloat
    var glow = false

    var body: some View {
        MarketTileSurface(
            color: MarketTileStyle.color(hex: bundle.accent, name: bundle.id), size: size, glow: glow
        ) {
            Image(systemName: bundle.icon)
                .font(.system(size: size * 0.44, weight: .semibold))
        }
    }
}

/// A small tile of one bot of a set, in the bot's own colour and symbol.
struct MemberMiniTile: View {
    let template: BotTemplate
    var size: CGFloat = 24

    var body: some View {
        MarketTileSurface(color: MarketTileStyle.color(hex: template.accent, name: template.id), size: size) {
            Image(systemName: template.icon)
                .font(.system(size: size * 0.46, weight: .semibold))
        }
        .help(template.nameEn)
        .accessibilityLabel(template.nameEn)
    }
}

// MARK: - the row and the cards

/// The row of sets above the bots: a section label and one card per set the filter and the search keep.
struct BundlesRow: View {
    let bundles: [AgentBundle]
    let templates: [BotTemplate]
    let languageCode: String
    var onView: (AgentBundle) -> Void

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(L10n.Market.Bundles.title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(bundles) { bundle in
                    BundleCard(
                        bundle: bundle,
                        members: BundleLogic.members(of: bundle, templates: templates),
                        languageCode: languageCode,
                        onView: { onView(bundle) })
                }
            }
        }
    }
}

/// A set: its tile, its name and description, the small tiles of the bots it holds, and View.
struct BundleCard: View {
    let bundle: AgentBundle
    let members: [BotTemplate]
    let languageCode: String
    var onView: () -> Void

    var body: some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    BundleTile(bundle: bundle, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bundle.name(languageCode: languageCode))
                            .font(BanditoFont.display(size: 13.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(bundle.description(languageCode: languageCode))
                            .font(BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineLimit(2, reservesSpace: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    ForEach(members) { member in
                        MemberMiniTile(template: member)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 24)
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.Market.view, action: onView)
                        .banditoButton(.lightPill())
                        .fixedSize()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        }
        .onTapGesture(perform: onView)
    }
}

// MARK: - the panel

/// The panel of one set. The first stage shows the bots, the services and the runtime, and makes the team. The second
/// shows what was made and what was not, and opens the first bot of the team.
struct BundlePanel: View {
    let bundle: AgentBundle
    let members: [BotTemplate]
    let services: [BotLogic.Service]
    let server: ServerModel
    let languageCode: String
    /// True while the daemon makes the team: the panel then cannot be closed.
    @Binding var creating: Bool
    var onClose: () -> Void
    var onConnect: (IntegrationCatalogEntry) -> Void

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var runtime: RuntimeKind?
    @State private var result: BundleCreation?
    @State private var error: UserFacingMessage?

    init(
        bundle: AgentBundle, members: [BotTemplate], services: [BotLogic.Service], server: ServerModel,
        languageCode: String, creating: Binding<Bool>, onClose: @escaping () -> Void,
        onConnect: @escaping (IntegrationCatalogEntry) -> Void
    ) {
        self.bundle = bundle
        self.members = members
        self.services = services
        self.server = server
        self.languageCode = languageCode
        _creating = creating
        self.onClose = onClose
        self.onConnect = onConnect
        _runtime = State(
            initialValue: BundleLogic.runtime(
                keeping: nil, available: BotLogic.availableRuntimes(server.runtimes)))
    }

    private var available: [RuntimeKind] { BotLogic.availableRuntimes(server.runtimes) }

    var body: some View {
        VStack(spacing: 0) {
            BundlePanelHeader(bundle: bundle, languageCode: languageCode, subtitle: subtitle)
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            if let result {
                resultBody(result)
                MarketPanelFooter {
                    Spacer(minLength: 8)
                    if let first = BundleLogic.firstAgent(result) {
                        Button(L10n.Common.close, action: onClose)
                            .banditoButton(.quiet())
                            .fixedSize()
                        Button(L10n.Market.Bundle.openFirst(name: first.name)) { openFirst(first) }
                            .banditoButton(.signal())
                            .fixedSize()
                    } else {
                        Button(L10n.Common.close, action: onClose)
                            .banditoButton(.quiet())
                            .fixedSize()
                    }
                }
            } else {
                detailBody
                MarketPanelFooter {
                    Spacer(minLength: 8)
                    Button(L10n.Common.close, action: onClose)
                        .banditoButton(.quiet())
                        .disabled(creating)
                        .fixedSize()
                    Button(creating ? L10n.Market.Bundle.creating : L10n.Market.Bundle.create) { create() }
                        .banditoButton(.signal())
                        .disabled(creating || runtime == nil)
                        .fixedSize()
                }
            }
        }
        .task {
            // The server's programs may not be known yet; the choice takes the first one that is ready.
            _ = try? await server.refreshRuntimes()
        }
        .onChange(of: available) { _, now in
            runtime = BundleLogic.runtime(keeping: runtime, available: now)
        }
    }

    private var subtitle: String {
        guard let result else { return bundle.description(languageCode: languageCode) }
        return L10n.Market.Bundle.resultTitle(
            created: String(BundleLogic.madeCount(result)), total: String(result.agents.count))
    }

    // MARK: first stage

    private var detailBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                membersSection
                if !services.isEmpty { servicesSection }
                runtimeField
                missingNotice
                if let error {
                    UserFacingErrorView(message: error, onRetry: error.canRetry ? { create() } : nil)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 460)
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.Market.Bundle.members)
            ForEach(members) { member in
                HStack(alignment: .top, spacing: 12) {
                    BotTile(template: member, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name(languageCode: languageCode))
                            .font(BanditoFont.text(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(member.description(languageCode: languageCode))
                            .font(BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Market.Bundle.services)
            ForEach(services) { service in
                BotServiceRow(service: service, onConnect: onConnect)
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
                        get: { runtime ?? available[0] },
                        set: { runtime = $0 }),
                    sections: [
                        SelectSection(options: available.map { SelectOption(value: $0, title: $0.title) })
                    ],
                    label: L10n.AgentSheet.runtime, placeholder: "")
                .disabled(creating)
            }
        }
    }

    /// A required service that is not connected: the team is made anyway, but its bots that use the service cannot do
    /// their job until it is connected, so the panel says so.
    @ViewBuilder
    private var missingNotice: some View {
        let missing = BotLogic.missingRequired(services)
        if !missing.isEmpty {
            Label {
                Text(L10n.Market.Bundle.missingRequired(names: missing.map(\.name).joined(separator: ", ")))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(BanditoFont.text(size: 12.5, weight: 400))
            .foregroundStyle(BanditoPalette.peach)
        }
    }

    // MARK: second stage

    private func resultBody(_ result: BundleCreation) -> some View {
        let rows = BundleLogic.rows(of: result, templates: members, languageCode: languageCode)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    resultRow(row)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 460)
    }

    private func resultRow(_ row: BundleLogic.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: resultSymbol(row))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(resultTint(row))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.agentName ?? row.name)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                if let problem = row.problem {
                    Text(problem)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !row.made {
                    Text(row.name)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
        }
    }

    private func resultSymbol(_ row: BundleLogic.Row) -> String {
        if !row.made { return "xmark.circle" }
        return row.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle"
    }

    private func resultTint(_ row: BundleLogic.Row) -> Color {
        if !row.made { return Color.Bandito.danger }
        return row.problem == nil ? Color.Bandito.ok : BanditoPalette.peach
    }

    // MARK: actions

    private func create() {
        guard !creating, let request = BundleLogic.request(bundle: bundle, runtime: runtime, languageCode: languageCode)
        else { return }
        creating = true
        error = nil
        Task {
            do {
                let made = try await server.createBundle(request)
                result = made
                creating = false
            } catch {
                self.error = UserFacingError.message(for: error)
                creating = false
            }
        }
    }

    /// The first bot of the team: its chat opens with the input focused, if the server in front is still this one.
    private func openFirst(_ agent: Agent) {
        if app.currentServer?.id == server.id {
            router.selectAgent(agent.id, on: server)
            router.select(mode: .team)
        }
        onClose()
    }
}

/// The head of the set's panel: the tile, the name and a line under it.
struct BundlePanelHeader: View {
    let bundle: AgentBundle
    let languageCode: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BundleTile(bundle: bundle, size: 48, glow: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.name(languageCode: languageCode))
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
