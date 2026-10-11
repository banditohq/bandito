import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI
import os

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

/// A small tile of one bot of a set, in the bot's own colour and symbol. Its tooltip is the bot's name in the app's
/// language.
struct MemberMiniTile: View {
    let template: BotTemplate
    let languageCode: String
    var size: CGFloat = 24

    var body: some View {
        let name = template.name(languageCode: languageCode)
        MarketTileSurface(color: MarketTileStyle.color(hex: template.accent, name: template.id), size: size) {
            Image(systemName: template.icon)
                .font(.system(size: size * 0.46, weight: .semibold))
        }
        .help(name)
        .accessibilityLabel(name)
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
                        MemberMiniTile(template: member, languageCode: languageCode)
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
/// shows what was made and what was not, and opens the first bot of the team. After a request that failed (a timeout,
/// a dropped connection) the daemon may have made some of the bots: the list is read again, and the next press makes
/// only the bots that are still missing.
struct BundlePanel: View {
    private static let log = Logger(subsystem: "dev.bandito", category: "bundles")

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
    /// A request failed: the bots already made are read from the list, and Create makes the rest.
    @State private var retrying = false

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
                    Button(createTitle) { create() }
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

    private var createTitle: String {
        if creating { return L10n.Market.Bundle.creating }
        return retrying ? L10n.Market.Bundle.createMissing : L10n.Market.Bundle.create
    }

    // MARK: first stage

    private var detailBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                membersSection
                if !services.isEmpty { servicesSection }
                runtimeField
                missingNotice
                if retrying {
                    Text(L10n.Market.Bundle.partial)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(BanditoPalette.peach)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// One bot of the result. The daemon's own words are not shown: they go to the log and the tooltip.
    private func resultRow(_ row: BundleLogic.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: resultSymbol(row.outcome))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(resultTint(row.outcome))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.agentName ?? row.name)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                if let note = outcomeNote(row.outcome) {
                    Text(note)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(row.problem ?? "")
    }

    private func resultSymbol(_ outcome: BundleLogic.Outcome) -> String {
        switch outcome {
        case .made: "checkmark.circle.fill"
        case .madeWithProblem: "exclamationmark.triangle"
        case .notMade: "xmark.circle"
        }
    }

    private func resultTint(_ outcome: BundleLogic.Outcome) -> Color {
        switch outcome {
        case .made: Color.Bandito.ok
        case .madeWithProblem: BanditoPalette.peach
        case .notMade: Color.Bandito.danger
        }
    }

    private func outcomeNote(_ outcome: BundleLogic.Outcome) -> String? {
        switch outcome {
        case .made: nil
        case .madeWithProblem: L10n.Market.Bundle.Status.madeWithProblem
        case .notMade: L10n.Market.Bundle.Status.notMade
        }
    }

    // MARK: actions

    /// Makes the team. After a failed request only the bots without a recent agent of their template are asked for, and
    /// the answer lists the bots made before as well.
    private func create() {
        guard !creating, let runtime else { return }
        let now = Date()
        let earlier = retrying ? BundleLogic.recentEntries(members: members, agents: server.agents, now: now) : []
        let targets = retrying ? BundleLogic.remaining(members: members, agents: server.agents, now: now) : members
        error = nil
        creating = true
        Task {
            do {
                var made = BundleCreation()
                if !targets.isEmpty {
                    guard let request = BundleLogic.request(
                        bundle: bundle, runtime: runtime, languageCode: languageCode,
                        templates: retrying ? targets.map(\.id) : nil)
                    else {
                        creating = false
                        return
                    }
                    made = try await server.createBundle(request)
                }
                let answer = retrying ? BundleLogic.combined(members: members, earlier: earlier, made: made) : made
                for row in BundleLogic.rows(of: answer, templates: members, languageCode: languageCode) {
                    if let problem = row.problem {
                        Self.log.error("bundle \(bundle.id, privacy: .public) \(row.id, privacy: .public): \(problem, privacy: .public)")
                    }
                }
                result = answer
                retrying = false
                creating = false
            } catch {
                Self.log.error("agents.create_bundle \(bundle.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.error = UserFacingError.message(for: error)
                // The daemon may have made some of the bots before the request failed: read the list first.
                try? await server.readAgentsNow()
                retrying = true
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
