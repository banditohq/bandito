import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "New agent": ready teams or one agent (docs/IOS_APP.md, Hire your first crew). Opened from Crew's "+" and from its
/// empty state. It closes once the agent or the team is made; the server model already holds what the daemon made.
struct NewAgentSheet: View {
    let server: ServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab

    enum Tab: Hashable { case teams, one }

    /// Opens on `tab`: the ready teams unless the caller asks for the one-agent form (the screenshots do).
    init(server: ServerModel, tab: Tab = .teams) {
        self.server = server
        _tab = State(initialValue: tab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L10n.Ios.NewAgent.tabTeams).tag(Tab.teams)
                    Text(L10n.Ios.NewAgent.tabOne).tag(Tab.one)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, BanditoSpace.s5)
                .padding(.vertical, BanditoSpace.s2)
                .accessibilityIdentifier("newAgent.tabs")

                switch tab {
                case .teams:
                    ReadyTeamsList(server: server, onMade: { dismiss() })
                case .one:
                    OneAgentForm(server: server, onMade: { dismiss() })
                }
            }
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(L10n.AgentSheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
    }
}

/// The ready teams of the server, in the order of `ReadyTeamsLogic.ids`. A tap opens the team's preview.
struct ReadyTeamsList: View {
    let server: ServerModel
    let onMade: () -> Void

    @State private var teams: [AgentBundle]?

    var body: some View {
        Group {
            if !ReadyTeamsLogic.supported(server.supports) {
                message(L10n.ReadyTeam.unavailable)
            } else if let teams {
                if teams.isEmpty {
                    message(L10n.Ios.NewAgent.teamsEmpty)
                } else {
                    List {
                        ForEach(teams) { team in
                            NavigationLink(value: team) {
                                TeamRow(bundle: team)
                            }
                            .listRowBackground(Color.Bandito.surface1)
                            .accessibilityIdentifier("newAgent.team.\(team.id)")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationDestination(for: AgentBundle.self) { team in
            ReadyTeamPreview(server: server, bundle: team, onMade: onMade)
        }
        .task {
            guard ReadyTeamsLogic.supported(server.supports) else { return }
            let all = (try? await server.agentBundles()) ?? []
            teams = ReadyTeamsLogic.teams(from: all)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 15))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(BanditoSpace.s6)
    }
}

/// One ready team in the list: its tile in the team's colour, its name and what it does.
struct TeamRow: View {
    let bundle: AgentBundle

    var body: some View {
        HStack(spacing: BanditoSpace.s3) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: bundle.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.Bandito.bg)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.name(languageCode: AgentForms.languageCode))
                    .font(BanditoFont.display(size: 16, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(bundle.description(languageCode: AgentForms.languageCode))
                    .font(BanditoFont.text(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, BanditoSpace.s1)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        bundle.accent.flatMap(AvatarHex.value).map { Color(rgb: $0) } ?? Color.Bandito.signal
    }
}

/// A ready team before it is made: its agents with their rights, its schedules (all off until switched on), the
/// model it starts on, and the folder the team shares. "Create team" makes the agents in one request.
struct ReadyTeamPreview: View {
    let server: ServerModel
    let bundle: AgentBundle
    let onMade: () -> Void

    @State private var members: [BotTemplate] = []
    @State private var enabled: Set<String> = []
    @State private var root: String?
    @State private var busy = false
    @State private var failure: String?
    @State private var madeCount = 0

    private var runtime: RuntimeKind? {
        AgentForms.defaultRuntime(server.runtimes)
    }

    private var model: String? {
        guard let runtime else { return nil }
        return ReadyTeamsLogic.model(runtime: runtime, models: server.runtimeModels[runtime.rawValue]?.models ?? [])
    }

    /// The team's schedules in words (`ReadyTeamsLogic`): all of them, each off until the person switches it on.
    private var schedules: [ReadyTeamsLogic.ScheduleItem] {
        ReadyTeamsLogic.scheduleItems(members: members, languageCode: AgentForms.languageCode)
    }

    /// The folder the team gets: the agents folder, and the team's name (a free name is taken when it is made).
    private var folderPreview: String? {
        guard let root else { return nil }
        return NewAgentFolderRules.folderPath(
            root: root, name: NewAgentFolderRules.folderName(for: bundle.name(languageCode: AgentForms.languageCode)))
    }

    private var canCreate: Bool {
        folderPreview != nil && ReadyTeamsLogic.canCreate(runtime: runtime, folder: folderPreview ?? "", members: members, busy: busy)
    }

    var body: some View {
        List {
            Section {
                Text(bundle.description(languageCode: AgentForms.languageCode))
                    .font(BanditoFont.text(size: 14))
                    .foregroundStyle(Color.Bandito.text2)
                    .listRowBackground(Color.Bandito.surface1)
            }

            Section {
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name(languageCode: AgentForms.languageCode))
                            .font(BanditoFont.display(size: 15, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        Text(permissionsLine(member))
                            .font(BanditoFont.text(size: 13))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                    .listRowBackground(Color.Bandito.surface1)
                }
            } header: {
                Text(L10n.ReadyTeam.agents)
            }

            if !schedules.isEmpty {
                Section {
                    ForEach(schedules) { item in
                        Toggle(isOn: binding(for: item.key)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.agentName)
                                    .foregroundStyle(Color.Bandito.text)
                                Text(item.when)
                                    .font(item.isCron ? BanditoFont.mono(size: 12) : BanditoFont.text(size: 12))
                                    .foregroundStyle(Color.Bandito.text3)
                            }
                        }
                        .listRowBackground(Color.Bandito.surface1)
                    }
                } header: {
                    Text(L10n.ReadyTeam.schedules)
                } footer: {
                    Text(L10n.ReadyTeam.schedulesHint)
                }
            }

            Section {
                Text(modelLine)
                    .foregroundStyle(Color.Bandito.text)
                    .listRowBackground(Color.Bandito.surface1)
            } header: {
                Text(L10n.AgentSheet.model)
            }

            Section {
                if let folderPreview {
                    Text(folderPreview)
                        .font(BanditoFont.mono(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .listRowBackground(Color.Bandito.surface1)
                }
            } header: {
                Text(L10n.ReadyTeam.folder)
            } footer: {
                Text(L10n.ReadyTeam.folderShared)
            }

            if let failure {
                Section {
                    Text(failure)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.danger)
                        .listRowBackground(Color.Bandito.surface1)
                        .accessibilityIdentifier("newAgent.team.error")
                }
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Spacer()
                        Text(busy ? L10n.ReadyTeam.creating : L10n.ReadyTeam.create)
                        Spacer()
                    }
                }
                .disabled(!canCreate)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("newAgent.team.create")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle(bundle.name(languageCode: AgentForms.languageCode))
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: madeCount)
        .task {
            let all = (try? await server.botTemplates()) ?? []
            members = bundle.templates.compactMap { id in all.first { $0.id == id } }
            root = await AgentFolders.root(server: server)
            if runtime == nil {
                try? await server.refreshRuntimes()
            }
            if server.runtimeModels.isEmpty {
                try? await server.refreshRuntimeModels()
            }
        }
    }

    private var modelLine: String {
        if let model {
            return L10n.ReadyTeam.model(name: model)
        }
        return L10n.ReadyTeam.modelDefault
    }

    private func permissionsLine(_ member: BotTemplate) -> String {
        let titles = ReadyTeamsLogic.permissions(of: member).map(\.title)
        return titles.isEmpty ? L10n.ReadyTeam.noPermissions : L10n.ReadyTeam.permissions(list: titles.joined(separator: ", "))
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(key) },
            set: { on in
                if on { enabled.insert(key) } else { enabled.remove(key) }
            })
    }

    /// Makes the team's folder, then the agents in one `agents.create_bundle`. The team is made when every agent is.
    private func create() async {
        guard let runtime, let root else { return }
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let folder = try await AgentFolders.makeFree(
                root: root, base: NewAgentFolderRules.folderName(for: bundle.name(languageCode: AgentForms.languageCode)),
                server: server)
            guard let request = ReadyTeamsLogic.request(
                bundle: bundle, runtime: runtime, languageCode: AgentForms.languageCode, model: model,
                folder: folder, items: schedules, enabled: enabled)
            else { return }
            let made = try await server.createBundle(request)
            let done = made.agents.filter { $0.agent != nil && $0.error == nil }.count
            if done == made.agents.count, done > 0 {
                madeCount += 1
                onMade()
            } else {
                failure = L10n.Market.Bundle.resultTitle(created: String(done), total: String(made.agents.count))
            }
        } catch {
            failure = AgentForms.errorText(error)
        }
    }
}
