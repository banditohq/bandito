import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// The agent card: the avatar with its mood, the name and the role (both editable), the status with pause and resume,
/// the runtime, model and effort, the approvals, what the agent may do, its schedules, its project folder, and deleting
/// it. Each change is one RPC (`AgentDetailModel`). Opened from Crew's context menu; the chat's header uses it too.
struct AgentDetailView: View {
    let server: ServerModel
    let agentID: String

    @State private var model: AgentDetailModel
    @State private var draftName = ""
    @State private var draftRole = ""
    @State private var draftsLoaded = false
    @State private var confirmsDelete = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case name, role }

    init(server: ServerModel, agentID: String) {
        self.server = server
        self.agentID = agentID
        _model = State(initialValue: AgentDetailModel(server: server, agentID: agentID))
    }

    /// The agent as the server model holds it now; nil once it is deleted.
    private var agent: Agent? {
        server.agents.first { $0.id == agentID }
    }

    var body: some View {
        Group {
            if let agent {
                List {
                    identitySection(agent)
                    statusSection(agent)
                    workSection(agent)
                    approvalSection(agent)
                    permissionSection(agent)
                    scheduleSection
                    folderSection(agent)
                    deleteSection
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle(agent?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let agent, !draftsLoaded {
                draftName = agent.name
                draftRole = agent.role
                draftsLoaded = true
            }
            await model.loadSchedules()
            if server.runtimeModels.isEmpty {
                try? await server.refreshRuntimeModels()
            }
        }
        .onChange(of: focus) { old, new in
            if old != nil, new != old { commitIdentity() }
        }
        .sensoryFeedback(.success, trigger: model.savedCount)
        .confirmationDialog(
            L10n.Agent.Delete.confirm(name: agent?.name ?? ""), isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button(L10n.Ios.Agent.Delete.button, role: .destructive) {
                Task { await delete() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
    }

    // MARK: sections

    @ViewBuilder private func identitySection(_ agent: Agent) -> some View {
        Section {
            VStack(spacing: BanditoSpace.s3) {
                CrewAvatar(
                    name: agent.name, look: CrewLook(agent: agent), mood: mood(agent), size: 96
                )
                .accessibilityHidden(true)
                TextField(L10n.AgentSheet.name, text: $draftName)
                    .font(BanditoFont.display(size: 22, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .onSubmit(commitIdentity)
                    .accessibilityIdentifier("agent.detail.name")
                TextField(L10n.AgentSheet.rolePlaceholder, text: $draftRole)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .focused($focus, equals: .role)
                    .onSubmit(commitIdentity)
                    .accessibilityIdentifier("agent.detail.role")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BanditoSpace.s2)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private func statusSection(_ agent: Agent) -> some View {
        Section {
            HStack {
                Text(L10n.Inspector.state)
                    .foregroundStyle(Color.Bandito.text2)
                Spacer()
                Text(stateText(agent))
                    .foregroundStyle(Color.Bandito.text)
            }
            .listRowBackground(Color.Bandito.surface1)
            Button {
                Task { await model.setPaused(!agent.paused) }
            } label: {
                Text(agent.paused ? L10n.Agent.Menu.resume : L10n.Agent.Menu.pause)
                    .foregroundStyle(Color.Bandito.signal)
            }
            .listRowBackground(Color.Bandito.surface1)
            .accessibilityIdentifier("agent.detail.pause")
        }
    }

    @ViewBuilder private func workSection(_ agent: Agent) -> some View {
        let runtimeKinds = runtimeOptions(agent)
        let models = server.runtimeModels[agent.runtime.rawValue]?.models ?? []
        Section {
            Picker(L10n.AgentSheet.runtime, selection: runtimeBinding(agent)) {
                ForEach(runtimeKinds, id: \.self) { kind in
                    Text(runtimeName(kind)).tag(kind)
                }
            }
            .listRowBackground(Color.Bandito.surface1)
            Picker(L10n.AgentSheet.model, selection: modelBinding(agent)) {
                Text(L10n.ModelPicker.defaultPlain).tag("")
                ForEach(models) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .listRowBackground(Color.Bandito.surface1)
            if !agent.runtime.supportedEfforts.isEmpty {
                Picker(L10n.Effort.title, selection: effortBinding(agent)) {
                    // The runtime's default shows only while the agent has no effort; a level, once chosen, is kept.
                    if agent.effort == nil {
                        Text(L10n.ModelPicker.defaultPlain).tag(Effort?.none)
                    }
                    ForEach(agent.runtime.supportedEfforts, id: \.self) { level in
                        Text(effortName(level)).tag(Optional(level))
                    }
                }
                .listRowBackground(Color.Bandito.surface1)
            }
        } header: {
            Text(L10n.Inspector.sectionWork)
        }
    }

    @ViewBuilder private func approvalSection(_ agent: Agent) -> some View {
        Section {
            ForEach(AgentForms.approvalOrder, id: \.self) { mode in
                Button {
                    Task { await model.save(AgentPatch(approvalMode: mode)) }
                } label: {
                    HStack(alignment: .top, spacing: BanditoSpace.s3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(approvalTitle(mode))
                                .foregroundStyle(Color.Bandito.text)
                            Text(approvalHint(mode))
                                .font(BanditoFont.text(size: 13))
                                .foregroundStyle(Color.Bandito.text2)
                        }
                        Spacer(minLength: BanditoSpace.s2)
                        if agent.approvalMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.Bandito.signal)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.Bandito.surface1)
                .accessibilityAddTraits(agent.approvalMode == mode ? .isSelected : [])
            }
        } header: {
            Text(L10n.Inspector.approvals)
        }
    }

    @ViewBuilder private func permissionSection(_ agent: Agent) -> some View {
        let enabled = AgentCapability.set(from: agent.capabilities)
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: BanditoSpace.s2, alignment: .leading)],
                alignment: .leading, spacing: BanditoSpace.s2)
            {
                ForEach(AgentCapability.allCases) { permission in
                    PermissionChip(permission: permission, on: enabled.contains(permission)) {
                        togglePermission(permission, of: agent)
                    }
                }
            }
            .padding(.vertical, BanditoSpace.s1)
            .listRowBackground(Color.Bandito.surface1)
        } header: {
            Text(L10n.Capability.title)
        }
    }

    @ViewBuilder private var scheduleSection: some View {
        Section {
            if model.schedules.isEmpty {
                Text(L10n.Ios.Agent.noSchedules)
                    .foregroundStyle(Color.Bandito.text2)
                    .listRowBackground(Color.Bandito.surface1)
            }
            ForEach(model.schedules) { schedule in
                scheduleRow(schedule)
                    .listRowBackground(Color.Bandito.surface1)
            }
        } header: {
            Text(L10n.Inspector.schedules)
        }
    }

    @ViewBuilder private func folderSection(_ agent: Agent) -> some View {
        Section {
            VStack(alignment: .leading, spacing: BanditoSpace.s1) {
                Text(L10n.Inspector.placeFolder)
                    .font(BanditoFont.text(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                if let folder = NewAgentFolderRules.projectFolder(cwd: agent.cwd, homeDir: agent.homeDir) {
                    Text(folder)
                        .font(BanditoFont.mono(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                } else {
                    Text(L10n.AgentSheet.ownFolderHint)
                        .font(BanditoFont.text(size: 14))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            .listRowBackground(Color.Bandito.surface1)
        }
    }

    @ViewBuilder private var deleteSection: some View {
        Section {
            if let failure = model.failure {
                Text(L10n.Ios.Agent.error(message: failure))
                    .font(BanditoFont.text(size: 13))
                    .foregroundStyle(Color.Bandito.danger)
                    .listRowBackground(Color.Bandito.surface1)
                    .accessibilityIdentifier("agent.detail.error")
            }
            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Text(L10n.Ios.Agent.Delete.button)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.Bandito.danger)
            }
            .listRowBackground(Color.Bandito.surface1)
            .accessibilityIdentifier("agent.detail.delete")
        }
    }

    // MARK: rows

    private func togglePermission(_ permission: AgentCapability, of agent: Agent) {
        var next = AgentCapability.set(from: agent.capabilities)
        if next.contains(permission) {
            next.remove(permission)
        } else {
            next.insert(permission)
        }
        Task { await model.save(AgentPatch(capabilities: AgentCapability.wire(next))) }
    }

    private func scheduleRow(_ schedule: Schedule) -> some View {
        HStack(spacing: BanditoSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.title ?? firstLine(schedule.prompt))
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(scheduleWords(schedule))
                    .font(BanditoFont.text(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Spacer(minLength: BanditoSpace.s2)
            Button {
                Task { await model.runScheduleNow(schedule.id) }
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.Bandito.signal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Inspector.runNow)
            Toggle(isOn: Binding(
                get: { schedule.enabled },
                set: { value in Task { await model.setScheduleEnabled(schedule.id, value) } })
            ) {
                Text(schedule.title ?? firstLine(schedule.prompt))
            }
            .labelsHidden()
        }
    }

    // MARK: bindings and choices

    private func runtimeBinding(_ agent: Agent) -> Binding<RuntimeKind> {
        Binding(
            get: { agent.runtime },
            set: { kind in Task { await model.save(AgentPatch(runtime: kind)) } })
    }

    private func modelBinding(_ agent: Agent) -> Binding<String> {
        Binding(
            get: { agent.model ?? "" },
            set: { id in Task { await model.save(AgentEdit.model(id.isEmpty ? nil : id)) } })
    }

    /// The effort as the agent has it, clamped to what the runtime offers. The default (nil) is never sent back: the
    /// patch cannot clear an effort, so only a chosen level is saved.
    private func effortBinding(_ agent: Agent) -> Binding<Effort?> {
        Binding(
            get: { agent.effort.map { agent.runtime.clampedEffort($0) } },
            set: { level in
                guard let level else { return }
                Task { await model.save(AgentPatch(effort: level)) }
            })
    }

    /// The runtimes the server has installed, plus the agent's own when it is not among them (it still shows).
    private func runtimeOptions(_ agent: Agent) -> [RuntimeKind] {
        let installed = [RuntimeKind.claude, .codex, .grok].filter { kind in
            server.runtimes.contains { $0.kind == kind && $0.installed }
        }
        return installed.contains(agent.runtime) ? installed : installed + [agent.runtime]
    }

    private func commitIdentity() {
        guard let agent, let patch = AgentEdit.identity(name: draftName, role: draftRole, current: agent) else {
            draftName = agent?.name ?? draftName
            draftRole = agent?.role ?? draftRole
            return
        }
        Task { await model.save(patch) }
    }

    private func delete() async {
        guard await model.delete() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        dismiss()
    }

    // MARK: words

    private func mood(_ agent: Agent) -> AvatarMood {
        AvatarMood.crew(
            status: server.status(of: agent.id),
            turnRunning: server.threadSummary(for: agent.id).turnRunning,
            paused: agent.paused)
    }

    private func stateText(_ agent: Agent) -> String {
        if agent.paused { return L10n.Inspector.statePaused }
        switch server.status(of: agent.id) {
        case .idle: return L10n.Status.idle
        case .working: return L10n.Status.working
        case .needsYou: return L10n.Status.needsYou
        case .error: return L10n.Status.error
        case .offline: return L10n.Status.offline
        }
    }

    private func runtimeName(_ kind: RuntimeKind) -> String {
        switch kind {
        case .claude: L10n.Runtime.claude
        case .codex: L10n.Runtime.codex
        case .grok: L10n.Runtime.grok
        case .api: L10n.Runtime.api
        }
    }

    private func effortName(_ level: Effort) -> String {
        switch level {
        case .low: L10n.Effort.low
        case .medium: L10n.Effort.medium
        case .high: L10n.Effort.high
        case .xhigh: L10n.Effort.xhigh
        case .max: L10n.Effort.max
        }
    }

    private func approvalTitle(_ mode: ApprovalMode) -> String {
        switch mode {
        case .risky: L10n.ApprovalMode.risky
        case .always: L10n.ApprovalMode.always
        case .never: L10n.ApprovalMode.never
        }
    }

    private func approvalHint(_ mode: ApprovalMode) -> String {
        switch mode {
        case .risky: L10n.ApprovalMode.Hint.risky
        case .always: L10n.ApprovalMode.Hint.always
        case .never: L10n.ApprovalMode.Hint.never
        }
    }

    /// The schedule in words: the daemon's own reading, else the Mac's reading of the cron, else the cron itself.
    private func scheduleWords(_ schedule: Schedule) -> String {
        schedule.humanText(languageCode: AgentForms.languageCode)
            ?? BotScheduleWords.words(cron: schedule.cron, languageCode: AgentForms.languageCode)
            ?? schedule.cron
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}
