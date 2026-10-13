import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Step 5: "Hire your first crew". Left: the ready teams and "Just one agent". Right: the preview of the choice — who
/// joins, what each may do, the schedules in words, the folder, the runtime — and one tap in the flow's bottom bar
/// makes it. After a failed attempt the same tap makes only what is missing. When it is made, the bar says what is next.
struct CrewStep: View {
    var model: CrewModel
    /// The agent a relaunch remembers: the crew was made before, so it is shown as made and never made twice.
    var rememberedAgentID: String?
    /// The crew (or the agent) exists in full: the first agent is the one the first task goes to.
    var onMade: (_ first: Agent, _ teamID: String?) -> Void
    /// "Give them a task": on to the next step.
    var onContinue: () -> Void

    @State private var pickingFolder = false
    @State private var creating = false

    var body: some View {
        let _ = PerfCounters.hit("OnboardingCrewStep")
        VStack(alignment: .leading, spacing: 22) {
            header
            switch model.load {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Onboarding.Crew.loading)
                        .font(BanditoFont.text(size: 13.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
            case .failed(let message):
                HStack(spacing: 10) {
                    UserFacingErrorView(message: message)
                    Button(L10n.Onboarding.Server.retry) { Task { await model.reload() } }
                        .banditoButton(.quiet(size: .regular))
                }
            case .ready:
                content
            }
        }
        .frame(maxWidth: 800, alignment: .topLeading)
        .onboardingNext(nextAction)
        .task {
            await model.start()
            if let id = rememberedAgentID, let agent = model.server.agents.first(where: { $0.id == id }) {
                model.adopt(agent)
            }
        }
        .onChange(of: model.available) { _, _ in model.runtimesChanged() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isDone ? L10n.Onboarding.Crew.done : L10n.Onboarding.Crew.title)
                .font(BanditoFont.display(size: 35, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isDone {
                Text(L10n.Onboarding.Crew.subtitle)
                    .font(BanditoFont.text(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.isDone {
            madeList
        } else {
            HStack(alignment: .top, spacing: 22) {
                options
                    .frame(width: 250)
                preview
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let failure = model.failure {
                HStack(spacing: 10) {
                    UserFacingErrorView(message: failure)
                }
            }
        }
    }

    private var options: some View {
        VStack(spacing: 10) {
            ForEach(model.teams) { team in
                CrewOptionCard(
                    title: team.name(languageCode: model.languageCode),
                    text: team.description(languageCode: model.languageCode), bundle: team,
                    selected: model.choice == .team(team.id), locked: model.isLocked
                ) {
                    model.select(.team(team.id))
                }
                .equatable()
            }
            CrewOptionCard(
                title: L10n.Onboarding.Crew.Single.title, text: L10n.Onboarding.Crew.Single.text, bundle: nil,
                selected: model.choice == .single, locked: model.isLocked
            ) {
                model.select(.single)
            }
            .equatable()
            if model.teams.isEmpty {
                Text(L10n.Onboarding.Crew.noTeams)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: preview

    private var preview: some View {
        let _ = PerfCounters.hit("OnboardingCrewPreview")
        return VStack(alignment: .leading, spacing: 20) {
            switch model.choice {
            case .team:
                teamPreview
            case .single:
                singlePreview
            case nil:
                EmptyView()
            }
            folderSection
            runtimeSection
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.Bandito.text.opacity(0.09)))
    }

    @ViewBuilder
    private var teamPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(L10n.ReadyTeam.agents)
            ForEach(model.selectedMembers) { member in
                HStack(alignment: .top, spacing: 12) {
                    BotTile(template: member, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.name(languageCode: model.languageCode))
                            .font(BanditoFont.text(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(2)
                        Text(member.description(languageCode: model.languageCode))
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
            Text(model.modelLine)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        let items = model.scheduleItems
        if !items.isEmpty {
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
                        Toggle("", isOn: Binding(
                            get: { model.enabled.contains(item.key) },
                            set: { model.setSchedule(item.key, on: $0) }))
                            .labelsHidden()
                            .toggleStyle(BanditoToggleStyle())
                            .fixedSize()
                            .accessibilityLabel("\(item.agentName), \(item.when)")
                    }
                }
            }
        }
    }

    private func permissionsLine(_ member: BotTemplate) -> String {
        let list = ReadyTeamsLogic.permissions(of: member)
        guard !list.isEmpty else { return L10n.ReadyTeam.noPermissions }
        return L10n.ReadyTeam.permissions(list: list.map(\.title).joined(separator: ", "))
    }

    @ViewBuilder
    private var singlePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(L10n.Onboarding.Crew.role)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(AgentTemplate.allCases, id: \.self) { template in
                    let selected = model.template == template
                    Button(template.title) { model.setTemplate(template) }
                        .banditoButton(.quiet(size: .regular))
                        .overlay(
                            Capsule().stroke(selected ? Color.Bandito.signal : .clear, lineWidth: 1.5))
                        .disabled(model.isLocked)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(model.template.description)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Onboarding.Agent.nameLabel)
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                TextField(
                    model.template.title,
                    text: Binding(get: { model.name }, set: { model.setName($0) })
                )
                .banditoField()
                .font(BanditoFont.text(size: 14.5, weight: 400))
                .disabled(model.isLocked)
                if !model.name.isEmpty, let problem = model.nameProblem {
                    Text(Self.problemText(problem))
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                }
            }
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.ReadyTeam.folder)
            Text(model.choice == .single ? L10n.ReadyTeam.folderOwn : L10n.ReadyTeam.folderShared)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                pickingFolder.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(BanditoPalette.peach)
                    Text(model.folder.isEmpty ? L10n.ReadyTeam.chooseFolder : model.folder)
                        .font(model.folder.isEmpty ? BanditoFont.text(size: 13, weight: 400) : BanditoFont.mono(size: 13, weight: 400))
                        .foregroundStyle(model.folder.isEmpty ? Color.Bandito.text3 : Color.Bandito.text)
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
            .disabled(model.isLocked || creating)
            .popover(isPresented: $pickingFolder, arrowEdge: .top) {
                FolderPicker(
                    server: model.server,
                    selection: Binding(get: { model.folder }, set: { model.setFolder($0) })
                ) { pickingFolder = false }
            }
            .accessibilityLabel(L10n.AgentSheet.folderAccessibility)
            .accessibilityValue(model.folder)
        }
    }

    @ViewBuilder
    private var runtimeSection: some View {
        if model.available.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.AgentSheet.runtime)
                HStack(spacing: 6) {
                    ForEach(model.available, id: \.self) { kind in
                        Button(model.subscriptions.title(kind)) { model.chooseRuntime(kind) }
                            .banditoButton(.quiet(size: .regular))
                            .overlay(
                                Capsule().stroke(model.runtime == kind ? Color.Bandito.signal : .clear, lineWidth: 1.5))
                            .disabled(model.isLocked)
                            .accessibilityAddTraits(model.runtime == kind ? .isSelected : [])
                    }
                }
            }
        } else if model.available.isEmpty {
            Text(L10n.Onboarding.Crew.noRuntime)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(BanditoPalette.peach)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: made

    private var madeList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.madeAgents) { agent in
                HStack(spacing: 14) {
                    RaccoonAvatar(name: agent.name, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name)
                            .font(BanditoFont.display(size: 15, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(2)
                        if !agent.role.isEmpty {
                            Text(agent.role)
                                .font(BanditoFont.text(size: 12.5, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Bandito.ok)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.text.opacity(0.08)))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    // MARK: action

    private var nextAction: OnboardingNextAction? {
        guard model.load == .ready else { return nil }
        if model.isDone {
            return OnboardingNextAction(title: L10n.Onboarding.Crew.next, isEnabled: model.firstAgent != nil) {
                onContinue()
            }
        }
        let title = model.isBusy || creating
            ? L10n.Onboarding.Crew.hiring
            : (model.choice == .single ? L10n.Onboarding.Crew.hireOne : L10n.Onboarding.Crew.hire)
        return OnboardingNextAction(title: title, isEnabled: model.canCreate && !creating) {
            guard !creating else { return }
            creating = true
            Task {
                defer { creating = false }
                if let first = await model.create() { onMade(first, model.teamID) }
            }
        }
    }

    static func problemText(_ problem: AgentNameRule.Problem) -> String {
        switch problem {
        case .empty: L10n.Onboarding.Agent.Err.empty
        case .tooLong: L10n.Onboarding.Agent.Err.tooLong
        case .badCharacters: L10n.Onboarding.Agent.Err.badCharacters
        case .duplicate: L10n.Onboarding.Agent.Err.duplicate
        }
    }
}

/// One choice of the crew step: a tile, a name and a line, with the brand ring when chosen. `Equatable` on what it
/// draws (the action is not compared), so choosing one card does not build the others again.
private struct CrewOptionCard: View, Equatable {
    let title: String
    let text: String
    /// The team's bundle for its tile; nil for "Just one agent".
    let bundle: AgentBundle?
    let selected: Bool
    let locked: Bool
    let onSelect: () -> Void

    nonisolated static func == (lhs: CrewOptionCard, rhs: CrewOptionCard) -> Bool {
        lhs.title == rhs.title && lhs.text == rhs.text && lhs.bundle == rhs.bundle && lhs.selected == rhs.selected
            && lhs.locked == rhs.locked
    }

    var body: some View {
        let _ = PerfCounters.hit("OnboardingCrewOption")
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                if let bundle {
                    BundleTile(bundle: bundle, size: 34)
                } else {
                    RaccoonAvatar(name: AgentTemplate.builder.title, color: .cream, size: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(BanditoFont.display(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(text)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Color.Bandito.signal : Color.Bandito.text.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(locked && !selected)
        .banditoAnimation(BanditoMotion.ease, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
