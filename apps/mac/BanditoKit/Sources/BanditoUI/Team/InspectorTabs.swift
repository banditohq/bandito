import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// MARK: - Details

/// Settings of the agent: runtime and plan, model, effort, approvals, folder, schedules and instructions.
/// Every change goes to the daemon at once through `updateAgent`.
struct DetailsTab: View {
    var server: ServerModel
    var agent: Agent

    @State private var folder = ""
    @State private var instructions = ""
    @State private var schedules: [Schedule] = []
    @State private var integrations: [Integration] = []
    @Environment(Router.self) private var router
    @State private var deletingSchedule: Schedule?
    @State private var error: UserFacingMessage?
    /// Values the daemon changed on its own after the last change (for example an effort the runtime lacks).
    @State private var notes: [String] = []
    @State private var modelDraft = ""
    /// The folded "Advanced" row of the model section (the fallback runtime).
    @State private var advancedOpen = false
    /// "Read replies aloud" of this agent (kept on this Mac, see `ReadAloud`).
    @State private var readAloud = false
    @FocusState private var folderFocused: Bool
    /// The chips on screen, and the sends that have not been answered yet.
    @State private var chips = AgentCapability.allOn
    @State private var chipsSync = InFlightCounter()
    /// The "What it may do" chips as shown. A click sets them at once and sends the whole list; the agent's list is
    /// taken again only when no send is in flight (see `sendCapabilities`).
    private var capabilities: Binding<Set<AgentCapability>> {
        Binding(get: { chips }, set: { sendCapabilities($0) })
    }

    /// Sends the whole list of chips. A daemon without the field ignores it and the agent's list comes back as all on.
    private func sendCapabilities(_ next: Set<AgentCapability>) {
        chips = next
        chipsSync.begin()
        Task {
            defer { chipsSync.end() }
            do {
                _ = try await server.updateAgent(agent.id, patch: AgentPatch(capabilities: AgentCapability.wire(next)))
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    private var effort: Binding<Effort> {
        Binding(
            get: {
                RuntimeModelDisplay.effort(
                    agent.effort ?? .medium, modelID: agent.model ?? "", runtime: agent.runtime,
                    lists: server.runtimeModels) ?? .medium
            },
            set: { value in change { _ = try await server.updateAgent(agent.id, effort: value) } })
    }

    /// The effort levels the agent's saved model takes. Empty for a model that takes no effort.
    private var effortLevels: [Effort] {
        RuntimeModelDisplay.effortLevels(
            modelID: agent.model ?? "", runtime: agent.runtime, lists: server.runtimeModels)
    }

    /// Effort as one compact row under the model it belongs to: the levels are the model's own. A model that takes
    /// no effort says so in the row's value; the caption about what effort means is the row's tooltip.
    @ViewBuilder
    private var effortRow: some View {
        InspectorRow(label: L10n.Effort.title, compact: true) {
            if effortLevels.isEmpty {
                Text(L10n.ModelPicker.noEffort)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } else {
                BanditoSelect(
                    selection: effort,
                    sections: [SelectSection(options: effortLevels.map { SelectOption(value: $0, title: $0.title) })],
                    label: L10n.Effort.title, placeholder: effort.wrappedValue.title)
                    .frame(maxWidth: 260)
            }
        }
        .help(L10n.AgentSheet.effortCaption)
    }

    /// The folded "Advanced" row of the model section: its summary shows what differs from the default.
    private var advancedRow: some View {
        Button {
            advancedOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text3)
                    .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                    .frame(width: 12)
                Text(L10n.AgentSheet.advanced)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                Spacer(minLength: 10)
                if !advancedOpen, let fallback = agent.fallbackRuntime {
                    Text(L10n.AgentSheet.advancedFallback(runtime: fallback.title))
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 8))
        .accessibilityValue(advancedOpen ? L10n.AgentSheet.advancedExpanded : L10n.AgentSheet.advancedCollapsed)
    }

    /// One of the three calm sections of the card: a small heading over a card of rows.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            InspectorCard { content() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(L10n.Inspector.sectionWork) {
                InspectorRow(label: L10n.Inspector.state, compact: true) {
                    HStack(spacing: 10) {
                        Text(agent.paused ? L10n.Inspector.statePaused : L10n.Inspector.stateRunning)
                            .font(BanditoFont.text(size: 12.5, weight: 500))
                            .foregroundStyle(agent.paused ? Color.Bandito.text2 : Color.Bandito.text)
                        Button(agent.paused ? L10n.Agent.Menu.resume : L10n.Agent.Menu.pause) {
                            change { _ = try await server.setPaused(agentID: agent.id, !agent.paused) }
                        }
                        .banditoButton(.link)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .foregroundStyle(BanditoPalette.peach)
                        .disabled(!PauseActions.available(on: server))
                        .help(PauseActions.available(on: server) ? "" : L10n.Team.pauseUnavailable)
                    }
                }
                InspectorRow(label: L10n.Inspector.readAloud, compact: true) {
                    Toggle("", isOn: Binding(
                        get: { readAloud },
                        set: { on in
                            readAloud = on
                            ReadAloud.set(on, agentID: agent.id)
                        })
                    )
                    .labelsHidden()
                    .toggleStyle(BanditoToggleStyle())
                    .help(L10n.Inspector.readAloudHint)
                    .accessibilityLabel(L10n.Inspector.readAloud)
                }
                .task(id: agent.id) {
                    readAloud = ReadAloud.isOn(agentID: agent.id)
                }
                InspectorRow(label: L10n.Inspector.project, compact: true) {
                    // A long path is cut at its start ("…/projects/app") and the full path is in the tooltip. Clicking
                    // it turns into the field for editing.
                    if folderFocused {
                        TextField("", text: $folder)
                            .banditoField()
                            .font(BanditoFont.mono(size: 12.5, weight: 400))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                            .focused($folderFocused)
                            .onSubmit(saveFolder)
                    } else {
                        Text(folder)
                            .font(BanditoFont.mono(size: 12.5, weight: 400))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 200, alignment: .trailing)
                            .contentShape(Rectangle())
                            .help(folder)
                            .onTapGesture { folderFocused = true }
                    }
                }
            }

            section(L10n.Inspector.model) {
                InspectorRow(label: L10n.Inspector.runsOn, compact: true) {
                    BanditoSelect(
                        selection: runtimeBinding, sections: [SelectSection(options: runtimeChoices)],
                        label: L10n.Inspector.runsOn, placeholder: agent.runtime.title)
                        .frame(maxWidth: 260)
                }
                InspectorRow(label: L10n.Inspector.model, compact: true) {
                    ModelPicker(
                        runtime: agent.runtime, selection: $modelDraft,
                        models: server.runtimeModels[agent.runtime.rawValue],
                        status: server.runtimeModelsStatus, onCommit: saveModel)
                        .frame(maxWidth: 260)
                }
                effortRow
                advancedRow
                if advancedOpen {
                    InspectorRow(label: L10n.AgentSheet.fallbackLabel, compact: true) {
                        BanditoSelect(
                            selection: fallbackBinding, sections: [SelectSection(options: fallbackChoices)],
                            label: L10n.AgentSheet.fallbackLabel, placeholder: L10n.AgentSheet.fallbackNone)
                            .frame(maxWidth: 260)
                    }
                    .transition(.opacity)
                }
            }
            .banditoAnimation(BanditoMotion.ease, value: advancedOpen)

            section(L10n.Inspector.sectionAccess) {
                InspectorRow(label: L10n.Inspector.approvals, compact: true) {
                    BanditoSelect(
                        selection: approvalBinding,
                        sections: [SelectSection(options: ApprovalMode.allCases.map { SelectOption(value: $0, title: $0.title) })],
                        label: L10n.Inspector.approvals, placeholder: agent.approvalMode.title)
                        .frame(maxWidth: 260)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Capability.title)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    CapabilityChips(enabled: capabilities)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if !integrations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(L10n.Integrations.title)
                    AgentIntegrationsPicker(integrations: integrations, choice: integrationChoice)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(L10n.Inspector.scheduleHeader)
                    Spacer()
                    Button(L10n.Inspector.addSchedule) { router.sheet = .schedule(agentID: agent.id, existing: nil) }
                        .banditoButton(.link)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .foregroundStyle(BanditoPalette.peach)
                }
                if schedules.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.Schedule.emptyHint)
                            .font(BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.Inspector.addSchedule) { router.sheet = .schedule(agentID: agent.id, existing: nil) }
                            .banditoButton(.quiet())
                            .fixedSize()
                    }
                    .padding(.vertical, 6)
                } else {
                    InspectorCard {
                        ForEach(schedules) { schedule in
                            ScheduleRow(
                                schedule: schedule,
                                onToggle: { enabled in
                                    change {
                                        _ = try await server.updateSchedule(schedule.id, enabled: enabled)
                                        await loadSchedules()
                                    }
                                },
                                onRunNow: {
                                    change {
                                        try await server.runScheduleNow(schedule.id)
                                        await loadSchedules()
                                    }
                                },
                                onEdit: { router.sheet = .schedule(agentID: agent.id, existing: schedule) },
                                onDelete: { deletingSchedule = schedule })
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Inspector.instructionsHeader)
                // A vertical TextField, not TextEditor: this view is inside a ScrollView, and a TextEditor would take
                // the wheel for its own scrolling. Return adds a line; the field grows from 4 to 12 lines.
                TextField(L10n.Inspector.instructionsPlaceholder, text: $instructions, axis: .vertical)
                    .banditoField()
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .lineLimit(4...12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                HStack(spacing: 12) {
                    Text(L10n.Inspector.instructionsHint)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(L10n.Common.save) {
                        change { _ = try await server.updateAgent(agent.id, systemPrompt: instructions) }
                    }
                    .banditoButton(.quiet())
                    .fixedSize()
                    .disabled(instructions == (agent.systemPrompt ?? ""))
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }

            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(BanditoPalette.peach)
            }

            if let error {
                InspectorError(message: error)
            }
        }
        .onChange(of: agent.model, initial: true) { _, model in
            modelDraft = model ?? ""
        }
        .onChange(of: agent.capabilities, initial: true) { _, _ in
            if chipsSync.isIdle { chips = AgentCapability.set(from: agent.capabilities) }
        }
        .onChange(of: chipsSync.isIdle) { _, idle in
            if idle { chips = AgentCapability.set(from: agent.capabilities) }
        }
        .onChange(of: folderFocused) { _, focused in
            // Leaving the field without Return puts the saved path back.
            if !focused { folder = agent.cwd }
        }
        .task(id: agent.id) {
            chips = AgentCapability.set(from: agent.capabilities)
            folder = agent.cwd
            instructions = agent.systemPrompt ?? ""
            await loadSchedules()
            await loadIntegrations()
        }
        // The schedule sheet is the main window's sheet; reload the list when it closes.
        .onChange(of: router.sheet) { old, new in
            if case .schedule = old, new == nil { Task { await loadSchedules() } }
        }
        .confirmationDialog(
            L10n.Schedule.deleteTitle(name: deletingSchedule.map(Self.scheduleName) ?? ""),
            isPresented: Binding(get: { deletingSchedule != nil }, set: { if !$0 { deletingSchedule = nil } }),
            titleVisibility: .visible,
            presenting: deletingSchedule
        ) { schedule in
            Button(L10n.Common.delete, role: .destructive) {
                change {
                    try await server.deleteSchedule(schedule.id)
                    await loadSchedules()
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Schedule.deleteMessage)
        }
    }

    /// The runtime the agent runs on. Choosing another one switches it, as the old menu did.
    private var runtimeBinding: Binding<RuntimeKind> {
        Binding(
            get: { agent.runtime },
            set: { kind in
                if kind != agent.runtime {
                    switchRuntime(to: kind)
                }
            })
    }

    /// The three runtimes, each with its plan as the subtitle when the server reports one.
    private var runtimeChoices: [SelectOption<RuntimeKind>] {
        RuntimeKind.pickable.map { kind in
            let plan = server.usage.first { $0.runtime == kind.rawValue }?.plan?.label
            return SelectOption(value: kind, title: kind.title, subtitle: plan)
        }
    }

    private var fallbackBinding: Binding<RuntimeKind?> {
        Binding(get: { agent.fallbackRuntime }, set: { setFallback($0) })
    }

    private var fallbackChoices: [SelectOption<RuntimeKind?>] {
        let none = SelectOption<RuntimeKind?>(value: nil, title: L10n.AgentSheet.fallbackNone, icon: "minus")
        let runtimes = NewAgentDraft.fallbackOptions(for: agent.runtime).map { kind in
            SelectOption<RuntimeKind?>(value: kind, title: kind.title, icon: "arrow.right")
        }
        return [none] + runtimes
    }

    private var approvalBinding: Binding<ApprovalMode> {
        Binding(
            get: { agent.approvalMode },
            set: { mode in
                // Choosing the mode already set is not a change: no request.
                guard mode != agent.approvalMode else { return }
                change { _ = try await server.updateAgent(agent.id, approvalMode: mode) }
            })
    }

    private func saveFolder() {
        let path = folder.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path != agent.cwd else { return }
        change { _ = try await server.updateAgent(agent.id, cwd: path) }
    }

    private func loadSchedules() async {
        schedules = (try? await server.schedules(agentId: agent.id)) ?? []
    }

    /// The integrations of the server. A daemon without them shows no section.
    private func loadIntegrations() async {
        guard server.supports("integrations") else { return }
        integrations = (try? await server.integrations()) ?? []
    }

    /// The integrations the agent uses. Choosing one sends the whole choice as the agent's list.
    private var integrationChoice: Binding<IntegrationChoice> {
        Binding(
            get: { IntegrationChoice.from(agent.integrations) },
            set: { next in
                // Only ids the server still has are sent (an integration removed meanwhile is not offered).
                let existing = Set(integrations.map(\.id))
                change {
                    _ = try await server.updateAgent(
                        agent.id, patch: AgentPatch(integrations: next.limited(to: existing).patchChange))
                }
            })
    }

    /// A schedule's name in a sentence: its title, else its words, else its cron.
    static func scheduleName(_ schedule: Schedule) -> String {
        schedule.title
            ?? schedule.humanText(languageCode: ModelDescription.currentLanguageCode)
            ?? schedule.cron
    }

    /// Runs a change and shows its failure in the tab.
    private func change(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = UserFacingError.message(for: error) }
        }
    }

    /// Sends a patch and shows the daemon's notes about values it changed on its own.
    private func apply(_ patch: AgentPatch) {
        error = nil
        Task {
            do {
                let update = try await server.updateAgent(agent.id, patch: patch)
                notes = update.warnings
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    /// Moves the agent to another runtime. A fallback that becomes the primary is cleared in the same patch,
    /// because the daemon refuses a fallback equal to the primary runtime.
    private func switchRuntime(to kind: RuntimeKind) {
        var patch = AgentPatch(runtime: kind)
        if agent.fallbackRuntime == kind {
            patch.fallbackRuntime = .clear
            patch.fallbackModel = .clear
        }
        // A model is kept only when the new runtime's list names it; otherwise the new runtime gets its default.
        patch.model = RuntimeModelDisplay.modelChange(
            afterSwitchingTo: kind, current: agent.model ?? "", lists: server.runtimeModels)
        apply(patch)
    }

    private func setFallback(_ kind: RuntimeKind?) {
        // Choosing the fallback already set is not a change: no request.
        guard kind != agent.fallbackRuntime else { return }
        if let kind {
            apply(AgentPatch(fallbackRuntime: .set(kind)))
        } else {
            apply(AgentPatch(fallbackRuntime: .clear, fallbackModel: .clear))
        }
    }

    /// An empty model goes back to the runtime's default model. Saved when a model is picked or a typed id is confirmed.
    private func saveModel(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: FieldChange<String> = text.isEmpty ? .clear : .set(text)
        if text == (agent.model ?? "") { return }
        var patch = AgentPatch(model: next)
        // One request: a model change that needs another effort carries it along. Opening the inspector writes nothing.
        patch.effort = RuntimeModelDisplay.effortWrite(
            modelChangedFrom: agent.model ?? "", to: text, stored: agent.effort,
            runtime: agent.runtime, lists: server.runtimeModels)
        apply(patch)
    }
}

// MARK: - Memory

/// Chapter of the agent's memory, how chapters are split, and the memory files on the server.
struct MemoryTab: View {
    var server: ServerModel
    var agent: Agent

    @Environment(Router.self) private var router
    @State private var files: [FsEntry] = []
    @State private var error: UserFacingMessage?
    @State private var customOpen = false
    @State private var customDraft = ""

    private var budget: Int { agent.contextBudget ?? ContextUsage.defaultBudget }

    /// The context window of the agent's model, from its runtime's list: the model it names, or the default model
    /// when it names none. Nil when the list does not know it.
    private var modelWindow: Int? {
        guard let list = server.runtimeModels[agent.runtime.rawValue] else { return nil }
        guard let model = agent.model, !model.isEmpty else { return list.defaultModel?.contextWindow }
        return list.models.first { $0.id == model }?.contextWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            chapterCard
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Memory.splitHeader)
                VStack(spacing: 6) {
                    modeRow(.smart, title: L10n.Memory.smart, description: L10n.Memory.smartDesc, badge: L10n.Common.recommended)
                    modeRow(.daily, title: L10n.Memory.daily, description: L10n.Memory.dailyDesc)
                    modeRow(.full, title: L10n.Memory.full, description: L10n.Memory.fullDesc)
                }
                if agent.memoryMode == .smart {
                    chapterLengthRow
                }
            }
            filesSection
            if let error {
                InspectorError(message: error)
            }
        }
        .task(id: agent.id) { await loadFiles() }
    }

    private var chapterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Chapter.title(count: agent.chapter))
                    .font(BanditoFont.text(size: 14.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer()
                Text(L10n.Chapter.startedToday)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            let fraction = ContextUsage.fraction(tokens: agent.contextTokens, budget: agent.contextBudget)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Bandito.text.opacity(0.07))
                    Capsule()
                        .fill(LinearGradient(colors: [Color.Bandito.ok, Color.Bandito.ok.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 8)
            HStack {
                Text(L10n.Memory.occupied(tokens: agent.contextTokens.formatted()))
                Spacer()
                Text(L10n.Chapter.nextAt(limit: budget.formatted()))
            }
            .font(BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Chapter.explainer(name: agent.name))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
        }
        .padding(14)
        .banditoCard()
    }

    /// The chapter length as a menu under the split modes (smart chapters only). Sizes above the model's window are
    /// off. While the daemon's model list for the agent's runtime is still coming, the menu waits with a spinner.
    private var chapterLengthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            InspectorRow(label: L10n.Memory.chapterLength, compact: true) {
                HStack(spacing: 6) {
                    if modelsLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Menu {
                        ForEach(ChapterLength.presets, id: \.self) { tokens in
                            Button {
                                setBudget(tokens)
                            } label: {
                                if tokens == budget {
                                    Label(presetTitle(tokens), systemImage: "checkmark")
                                } else {
                                    Text(presetTitle(tokens))
                                }
                            }
                            .disabled(!ChapterLength.isAllowed(tokens, window: modelWindow))
                        }
                        Divider()
                        Button(L10n.Memory.chapterLengthCustom) {
                            customDraft = ChapterLength.thousandsText(budget)
                            customOpen = true
                        }
                    } label: {
                        Text(ChapterLength.label(budget))
                            .font(BanditoFont.text(size: 12.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(modelsLoading)
                }
            }
            if let modelWindow {
                Text(budget > modelWindow
                     ? L10n.Memory.chapterLengthTooLong(max: ChapterLength.label(modelWindow))
                     : L10n.Memory.chapterLengthModelMax(max: ChapterLength.label(modelWindow)))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(budget > modelWindow ? Color.Bandito.signal : Color.Bandito.text3)
                    .padding(.horizontal, 16)
            }
        }
        .help(L10n.Memory.chapterLengthHint)
        .popover(isPresented: $customOpen, arrowEdge: .trailing) { customPopover }
    }

    /// True while the list of the agent's runtime has not come from the daemon yet. A failed or unsupported request
    /// does not wait: the window is then unknown and every size is offered.
    private var modelsLoading: Bool {
        server.runtimeModelsStatus == .unknown && server.runtimeModels[agent.runtime.rawValue] == nil
    }

    /// A preset's menu title; the default size says so.
    private func presetTitle(_ tokens: Int) -> String {
        let label = ChapterLength.label(tokens)
        return tokens == ContextUsage.defaultBudget ? "\(label) · \(L10n.Memory.chapterLengthDefault)" : label
    }

    /// What the typed custom size says: nothing, a size that can be saved, or why not.
    private var customSize: CustomSize {
        ChapterLength.customSize(customDraft, current: budget, window: modelWindow)
    }

    private var customPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Memory.chapterLengthCustom)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            HStack(spacing: 6) {
                TextField("", text: $customDraft)
                    .banditoField()
                    .frame(width: 110)
                    .onSubmit { saveCustom() }
                Text("K")
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            if let problem = customProblem {
                Text(problem)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            HStack {
                Spacer()
                Button(L10n.Common.save) { saveCustom() }
                    .banditoButton(.signal())
                    .disabled(customSize.savable == nil)
            }
        }
        .padding(14)
        .frame(width: 240)
        .onChange(of: customDraft) { _, value in
            // Digits and one decimal comma, as typed: the field counts thousands.
            let cleaned = ChapterLength.cleanedInput(value)
            if cleaned != value { customDraft = cleaned }
        }
    }

    /// The message under the field: not a size at all or outside the daemon's range, or more than the model holds.
    private var customProblem: String? {
        switch customSize {
        case .invalid:
            L10n.Memory.chapterLengthInvalid
        case .aboveWindow:
            modelWindow.map { L10n.Memory.chapterLengthModelMax(max: ChapterLength.label($0)) }
        case .empty, .unchanged, .ok:
            nil
        }
    }

    private func saveCustom() {
        guard let tokens = customSize.savable else { return }
        customOpen = false
        setBudget(tokens)
    }

    /// Saves the chapter length; a failure is shown under the split modes.
    private func setBudget(_ tokens: Int) {
        error = nil
        Task {
            do { _ = try await server.updateAgent(agent.id, contextBudget: tokens) } catch { self.error = UserFacingError.message(for: error) }
        }
    }

    private func modeRow(_ mode: MemoryMode, title: String, description: String, badge: String? = nil) -> some View {
        let selected = agent.memoryMode == mode
        return Button {
            error = nil
            Task {
                do { _ = try await server.updateAgent(agent.id, memoryMode: mode) } catch { self.error = UserFacingError.message(for: error) }
            }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle().stroke(selected ? Color.Bandito.signal : Color.Bandito.text.opacity(0.25), lineWidth: selected ? 5 : 1.5)
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(BanditoFont.text(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        if let badge { Chip(text: badge, tone: .ok) }
                    }
                    Text(description)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineSpacing(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.Bandito.signal.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? Color.Bandito.signal.opacity(0.4) : Color.Bandito.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 13))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The memory files the agent keeps in its folder. Opening one shows it in a viewer over the chat.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(L10n.Memory.header)
                Spacer()
                Text(agent.homeDir ?? "")
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if agent.homeDir == nil {
                Text("—").foregroundStyle(Color.Bandito.text3)
            } else {
                InspectorCard {
                    ForEach(memoryItems, id: \.path) { item in
                        Button {
                            router.showInWorkbench(.file(path: item.path), agentID: agent.id)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.Bandito.text2)
                                    .frame(width: 30, height: 30)
                                    .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(BanditoFont.text(size: 13, weight: 500))
                                        .foregroundStyle(Color.Bandito.text)
                                    Text(item.meta)
                                        .font(BanditoFont.text(size: 11.5, weight: 400))
                                        .foregroundStyle(Color.Bandito.text3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(L10n.Keys.open)
                                    .font(BanditoFont.text(size: 11.5, weight: 600))
                                    .foregroundStyle(BanditoPalette.peach)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.Bandito.text3)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .banditoButton(.row(cornerRadius: 8))
                    }
                }
                Text(L10n.Memory.footer)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineSpacing(2)
            }
        }
    }

    private struct MemoryItem {
        var path: String
        var title: String
        var meta: String
        var symbol: String
        var isFile = false
    }

    /// The four places of the design, found among the folder's entries; missing ones are left out.
    private var memoryItems: [MemoryItem] {
        guard let home = agent.homeDir else { return [] }
        func entry(_ name: String) -> FsEntry? { files.first { $0.name == name } }
        var items: [MemoryItem] = []
        if let memory = entry("MEMORY.md") {
            let time = TeamTime.label(ms: memory.modifiedMs)
            items.append(MemoryItem(
                path: memory.path, title: "MEMORY.md", meta: L10n.Memory.memoryFile(time: time), symbol: "doc.text",
                isFile: memory.kind == .file))
        }
        if let notes = entry("notes") {
            items.append(MemoryItem(path: notes.path, title: L10n.Memory.notes, meta: "notes/", symbol: "list.bullet"))
        }
        if let journal = entry("journal") {
            items.append(MemoryItem(path: journal.path, title: L10n.Memory.journal, meta: "journal/", symbol: "calendar"))
        }
        if let filesEntry = entry("files") {
            items.append(MemoryItem(path: filesEntry.path, title: L10n.Memory.files, meta: "files/", symbol: "folder"))
        }
        return items.isEmpty ? [MemoryItem(path: home, title: L10n.Memory.header, meta: home, symbol: "folder")] : items
    }

    private func loadFiles() async {
        guard let home = agent.homeDir else { return }
        do {
            files = try await server.list(home).entries
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

// MARK: - Where it runs

/// Where the agent works: its workplace (and a change of it), its places, and the runtimes on this server with their plans.
struct WhereTab: View {
    var server: ServerModel
    var agent: Agent

    @Environment(Router.self) private var router
    @State private var workplaces: WorkspacesModel?
    /// The workplace the person picked, until the move is confirmed.
    @State private var pendingMove: MoveTarget?
    /// The daemon's notes on the last change (for example the new chapter).
    @State private var notes: [String] = []
    @State private var error: UserFacingMessage?

    /// A workplace to move the agent to: the shared server (`shared`) or a container.
    private struct MoveTarget: Identifiable {
        var id: String
        var name: String
    }

    private var inContainer: Bool { agent.workspaceId != Workspace.sharedID }
    private var current: Workspace? { workplaces?.workspace(agent.workspaceId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel(L10n.Inspector.workplace)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    Image(systemName: inContainer ? "shippingbox" : "house")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BanditoPalette.peach)
                        .frame(width: 34, height: 34)
                        .background(BanditoPalette.peach.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        // With the change select on, its field is the place's name: the title would say it twice.
                        if !showsChangeMenu {
                            Text(workplaceTitle)
                                .font(BanditoFont.text(size: 14, weight: 600))
                                .foregroundStyle(Color.Bandito.text)
                                .lineLimit(1)
                        }
                        Text(workplaceSubtitle)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    Spacer()
                    if showsChangeMenu {
                        changeMenu
                    }
                }
                if let error {
                    UserFacingErrorView(message: error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    place(L10n.Inspector.placeFolder, symbol: "folder") {
                        router.filesPath = agent.cwd
                        router.select(mode: .files)
                    }
                    place(L10n.Inspector.placeTerminal, symbol: "terminal") { router.select(mode: .terminals) }
                    if !inContainer {
                        place(L10n.Inspector.placeBrowser, symbol: "globe") { router.select(mode: .browser) }
                        place(L10n.Inspector.placeScreen, symbol: "display") { router.select(mode: .screen) }
                    }
                }
                if inContainer {
                    Text(L10n.Workspace.Location.noBrowser)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .banditoCard()

            SectionLabel(L10n.Inspector.usage)
            VStack(spacing: 8) {
                ForEach(server.runtimes, id: \.kind) { status in
                    runtimeRow(status)
                }
            }
        }
        .task(id: agent.workspaceId) {
            let model = WorkspacesModel(server: server)
            workplaces = model
            await model.load()
        }
        .confirmationDialog(
            pendingMove.map { L10n.Workspace.Move.title(name: $0.name) } ?? "",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Workspace.Move.confirm) {
                if let target = pendingMove { move(to: target) }
            }
        } message: {
            Text(L10n.Workspace.Move.chapter)
        }
    }

    private var workplaceTitle: String {
        guard inContainer else { return L10n.Workspace.Shared.title }
        if let current { return current.name }
        return workplaces?.loading == true ? L10n.Workspace.Location.loading : L10n.Workspace.Location.missing
    }

    private var workplaceSubtitle: String {
        guard inContainer else { return server.config.name }
        guard let current else { return "" }
        return current.isRunning ? L10n.Workspace.Status.running : L10n.Workspace.Status.stopped
    }

    /// Lists the shared server and the containers. Choosing one asks first: the agent starts a new chapter there.
    private var showsChangeMenu: Bool { workplaces?.supported == true }

    /// The place the agent runs in, shown as the field's name; choosing another place asks first.
    private var changeMenu: some View {
        BanditoSelect(
            selection: Binding(get: { agent.workspaceId }, set: { id in
                afterSelectPanelCloses { askMove(to: id) }
            }),
            sections: [SelectSection(options: workplaceChoices)],
            label: L10n.Workspace.Location.change, placeholder: workplaceTitle,
            style: .compact)
        .fixedSize()
    }

    /// The shared server, then the containers, from `SelectChoices.workplaces`.
    private var workplaceChoices: [SelectOption<String>] {
        SelectChoices.workplaces(
            sharedTitle: L10n.Workspace.Shared.title, sharedEnabled: inContainer,
            containers: (workplaces?.containers ?? []).map { SelectChoices.Place(id: $0.id, name: $0.name) },
            currentID: agent.workspaceId)
    }

    /// Asks before the move: the confirmation dialog runs `move(to:)`. The agent's own place asks nothing.
    private func askMove(to id: String) {
        guard id != agent.workspaceId else { return }
        if id == Workspace.sharedID {
            pendingMove = MoveTarget(id: id, name: L10n.Workspace.Shared.title)
        } else if let container = workplaces?.containers.first(where: { $0.id == id }) {
            pendingMove = MoveTarget(id: container.id, name: container.name)
        }
    }

    /// `agents.update {workspace_id}`. The daemon's warnings are shown under the header.
    private func move(to target: MoveTarget) {
        error = nil
        notes = []
        Task {
            do {
                let update = try await server.updateAgent(agent.id, patch: AgentPatch(workspaceId: target.id))
                notes = update.warnings
            } catch {
                self.error = WorkspaceText.message(for: error)
            }
        }
    }

    private func place(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12.5))
                Text(label)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.Bandito.text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Bandito.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        }
        .banditoButton(.row(cornerRadius: 10))
    }

    private func runtimeRow(_ status: RuntimeStatus) -> some View {
        let plan = server.usage.first { $0.runtime == status.kind.rawValue }?.plan?.label
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(status.kind.title)
                        .font(BanditoFont.text(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    if let plan { Chip(text: plan, tone: .signal) }
                }
                Text(status.installed ? (status.version ?? "") : L10n.Inspector.notInstalled)
                    .font(BanditoFont.font(size: 11.5, weight: 400, mono: status.installed))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if status.installed, let loggedIn = status.loggedIn {
                Chip(text: loggedIn ? L10n.Inspector.loggedIn : L10n.Inspector.loggedOut, tone: loggedIn ? .ok : .signal)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

// MARK: - Labels for settings values

extension ApprovalMode {
    /// Name of the approval mode as shown in the details.
    var title: String {
        switch self {
        case .risky: L10n.ApprovalMode.risky
        case .always: L10n.ApprovalMode.always
        case .never: L10n.ApprovalMode.never
        }
    }
}
