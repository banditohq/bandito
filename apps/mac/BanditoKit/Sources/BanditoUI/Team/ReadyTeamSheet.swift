import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import os

/// A catalog handed to the sheet, for a picture or a test that has no server to ask.
struct ReadyTeamPreview {
    var bundles: [AgentBundle]
    var templates: [BotTemplate]
}

/// The preview of a ready team before it is made: its agents with what each may do and the model they start on, the
/// schedules (all off until the person switches one on here), the one project folder they share, and the runtime.
/// Create makes the team with one `agents.create_bundle` and shows what was made.
struct ReadyTeamSheet: View {
    private static let log = Logger(subsystem: "dev.bandito", category: "bundles")

    let bundleID: String
    let server: ServerModel
    var preview: ReadyTeamPreview?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var bots = BotsMarketModel()
    @State private var runtime: RuntimeKind?
    @State private var folder = ""
    @State private var pickerOpen = false
    /// The keys of the schedules switched on. Empty at first: nothing runs before the person confirms it.
    @State private var enabled: Set<String> = []
    @State private var creating = false
    @State private var result: BundleCreation?
    @State private var error: UserFacingMessage?
    /// A request failed: the agents it made are read from the list, and Create makes only the missing ones.
    @State private var retrying = false

    private var languageCode: String { ModelDescription.currentLanguageCode }
    private var bundle: AgentBundle? { (preview?.bundles ?? bots.bundles).first { $0.id == bundleID } }
    private var members: [BotTemplate] {
        bundle.map { BundleLogic.members(of: $0, templates: preview?.templates ?? bots.templates) } ?? []
    }
    private var available: [RuntimeKind] { BotLogic.availableRuntimes(server.runtimes) }

    var body: some View {
        let _ = PerfCounters.hit("ReadyTeamSheet")
        VStack(spacing: 0) {
            if let bundle {
                BundlePanelHeader(bundle: bundle, languageCode: languageCode, subtitle: subtitle(bundle))
                Rectangle().fill(Color.Bandito.line).frame(height: 1)
                if let result {
                    resultBody(result, bundle: bundle)
                } else {
                    detailBody(bundle)
                }
                Rectangle().fill(Color.Bandito.line).frame(height: 1)
                footer(bundle)
            } else {
                missing
            }
        }
        .frame(width: 600, height: 620)
        .background(Color.Bandito.surface2)
        .task(id: server.id) {
            if preview == nil { await bots.load(from: server) }
            _ = try? await server.refreshRuntimes()
            runtime = BundleLogic.runtime(keeping: runtime, available: available)
        }
        .onChange(of: available) { _, now in runtime = BundleLogic.runtime(keeping: runtime, available: now) }
    }

    private func subtitle(_ bundle: AgentBundle) -> String {
        guard let result else { return bundle.description(languageCode: languageCode) }
        return L10n.Market.Bundle.resultTitle(
            created: String(BundleLogic.madeCount(result)), total: String(result.agents.count))
    }

    /// Before the catalog arrives (or when the daemon has no such team) the sheet only says so.
    private var missing: some View {
        VStack(spacing: 14) {
            if bots.loaded || bots.failure != nil {
                Text(L10n.ReadyTeam.unavailable)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.quiet())
                    .fixedSize()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: first stage

    private func detailBody(_ bundle: AgentBundle) -> some View {
        let items = ReadyTeamsLogic.scheduleItems(members: members, languageCode: languageCode)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                agentsSection
                if !items.isEmpty { schedulesSection(items) }
                folderSection
                runtimeSection
                if let error {
                    UserFacingErrorView(message: error, onRetry: error.canRetry ? { create(bundle) } : nil)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(L10n.ReadyTeam.agents)
            ForEach(members) { member in
                HStack(alignment: .top, spacing: 12) {
                    BotTile(template: member, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.name(languageCode: languageCode))
                            .font(BanditoFont.text(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(2)
                        Text(member.description(languageCode: languageCode))
                            .font(BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(permissionsLine(member))
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(modelLine)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionsLine(_ member: BotTemplate) -> String {
        let list = ReadyTeamsLogic.permissions(of: member)
        guard !list.isEmpty else { return L10n.ReadyTeam.noPermissions }
        return L10n.ReadyTeam.permissions(list: list.map(\.title).joined(separator: ", "))
    }

    /// The model the team starts on, by the runtime in the field: the model's name, or the runtime's own default.
    private var modelLine: String {
        guard let runtime, let id = ReadyTeamsLogic.model(runtime: runtime, models: models(for: runtime)) else {
            return L10n.ReadyTeam.modelDefault
        }
        let name = models(for: runtime).first { $0.id == id }?.name ?? id
        return L10n.ReadyTeam.model(name: name)
    }

    private func models(for runtime: RuntimeKind) -> [RuntimeModel] {
        server.runtimeModels[runtime.rawValue]?.models ?? []
    }

    private func schedulesSection(_ items: [ReadyTeamsLogic.ScheduleItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.ReadyTeam.schedules)
            Text(L10n.ReadyTeam.schedulesHint)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(items) { item in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.agentName)
                            .font(BanditoFont.text(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(2)
                        Text(item.when)
                            .font(item.isCron ? BanditoFont.mono(size: 12, weight: 400) : BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: binding(for: item.key))
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                        .fixedSize()
                        .disabled(creating)
                        .accessibilityLabel(item.agentName)
                }
            }
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(key) },
            set: { on in
                if on { enabled.insert(key) } else { enabled.remove(key) }
            })
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.ReadyTeam.folder)
            Text(ReadyTeamsLogic.folderRequired(members: members) ? L10n.ReadyTeam.folderShared : L10n.ReadyTeam.folderOwn)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    pickerOpen.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                            .foregroundStyle(BanditoPalette.peach)
                        Text(folder.isEmpty ? L10n.ReadyTeam.chooseFolder : folder)
                            .font(folder.isEmpty ? BanditoFont.text(size: 13, weight: 400) : BanditoFont.mono(size: 13, weight: 400))
                            .foregroundStyle(folder.isEmpty ? Color.Bandito.text3 : Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .banditoButton(.row(cornerRadius: 12))
                .disabled(creating)
                .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                    FolderPicker(server: server, selection: $folder) { pickerOpen = false }
                }
                .accessibilityLabel(L10n.AgentSheet.folderAccessibility)
                .accessibilityValue(folder)
                if !ReadyTeamsLogic.folderRequired(members: members) && !folder.isEmpty {
                    Button {
                        folder = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    .banditoButton(.icon(size: 26, label: L10n.AgentSheet.folderClear))
                    .help(L10n.AgentSheet.folderClear)
                }
            }
        }
    }

    private var runtimeSection: some View {
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
                    selection: Binding(get: { runtime ?? available[0] }, set: { runtime = $0 }),
                    sections: [SelectSection(options: available.map { SelectOption(value: $0, title: $0.title) })],
                    label: L10n.AgentSheet.runtime, placeholder: ""
                )
                .disabled(creating)
            }
        }
    }

    // MARK: second stage

    private func resultBody(_ result: BundleCreation, bundle: AgentBundle) -> some View {
        let rows = BundleLogic.rows(of: result, templates: members, languageCode: languageCode)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(row.outcome))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint(row.outcome))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.agentName ?? row.name)
                                .font(BanditoFont.text(size: 13, weight: 600))
                                .foregroundStyle(Color.Bandito.text)
                                .lineLimit(2)
                            if let note = note(row.outcome) {
                                Text(note)
                                    .font(BanditoFont.text(size: 12.5, weight: 400))
                                    .foregroundStyle(Color.Bandito.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .help(row.problem ?? "")
                }
                if !result.missingIntegrations.isEmpty {
                    Text(L10n.ReadyTeam.connectServices(names: result.missingIntegrations.map(\.id).joined(separator: ", ")))
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(BanditoPalette.peach)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func symbol(_ outcome: BundleLogic.Outcome) -> String {
        switch outcome {
        case .made: "checkmark.circle.fill"
        case .madeWithProblem: "exclamationmark.triangle"
        case .notMade: "xmark.circle"
        }
    }

    private func tint(_ outcome: BundleLogic.Outcome) -> Color {
        switch outcome {
        case .made: Color.Bandito.ok
        case .madeWithProblem: BanditoPalette.peach
        case .notMade: Color.Bandito.danger
        }
    }

    private func note(_ outcome: BundleLogic.Outcome) -> String? {
        switch outcome {
        case .made: nil
        case .madeWithProblem: L10n.Market.Bundle.Status.madeWithProblem
        case .notMade: L10n.Market.Bundle.Status.notMade
        }
    }

    // MARK: footer and actions

    private func footer(_ bundle: AgentBundle) -> some View {
        HStack {
            ActionRow {
                if let result {
                    Button(L10n.Common.close) { dismiss() }
                        .banditoButton(.quiet())
                        .fixedSize()
                    if let first = BundleLogic.firstAgent(result) {
                        Button(L10n.Market.Bundle.openFirst(name: first.name)) { openFirst(first) }
                            .banditoButton(.signal())
                            .fixedSize()
                    }
                } else {
                    Button(L10n.Common.cancel) { dismiss() }
                        .banditoButton(.quiet())
                        .disabled(creating)
                        .fixedSize()
                    Button(creating ? L10n.ReadyTeam.creating : L10n.ReadyTeam.create) { create(bundle) }
                        .banditoButton(.signal())
                        .disabled(!ReadyTeamsLogic.canCreate(runtime: runtime, folder: folder, members: members, busy: creating))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func create(_ bundle: AgentBundle) {
        guard !creating, let runtime else { return }
        let items = ReadyTeamsLogic.scheduleItems(members: members, languageCode: languageCode)
        guard
            var request = ReadyTeamsLogic.request(
                bundle: bundle, runtime: runtime, languageCode: languageCode,
                model: ReadyTeamsLogic.model(runtime: runtime, models: models(for: runtime)), folder: folder,
                items: items, enabled: enabled)
        else { return }
        let now = Date()
        let earlier = retrying ? BundleLogic.recentEntries(members: members, agents: server.agents, now: now) : []
        let targets = retrying ? BundleLogic.remaining(members: members, agents: server.agents, now: now) : members
        request.templates = retrying ? targets.map(\.id) : nil
        error = nil
        creating = true
        Task {
            defer { creating = false }
            do {
                var made = BundleCreation()
                if !targets.isEmpty {
                    made = try await server.createBundle(request)
                    Telemetry.count(.agentCreate(.bundle))
                }
                let answer = retrying ? BundleLogic.combined(members: members, earlier: earlier, made: made) : made
                for row in BundleLogic.rows(of: answer, templates: members, languageCode: languageCode) {
                    if let problem = row.problem {
                        Self.log.error("ready team \(bundle.id, privacy: .public) \(row.id, privacy: .public): \(problem, privacy: .public)")
                    }
                }
                result = answer
                retrying = false
            } catch {
                Self.log.error("agents.create_bundle \(bundle.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.error = UserFacingError.message(for: error)
                // The daemon may have made some of the agents before the request failed: read the list first.
                try? await server.readAgentsNow()
                retrying = true
            }
        }
    }

    /// The first agent of the team: its chat opens, if the server in front is still this one.
    private func openFirst(_ agent: Agent) {
        if app.currentServer?.id == server.id {
            router.selectAgent(agent.id, on: server)
            router.select(mode: .team)
        }
        dismiss()
    }
}
