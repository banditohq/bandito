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
    @State private var showingNewSchedule = false
    @State private var error: UserFacingMessage?
    /// Values the daemon changed on its own after the last change (for example an effort the runtime lacks).
    @State private var notes: [String] = []
    @State private var modelDraft = ""

    private var effort: Binding<Effort> {
        Binding(
            get: { agent.effort ?? .medium },
            set: { value in change { _ = try await server.updateAgent(agent.id, effort: value) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorCard {
                InspectorRow(label: L10n.Inspector.state) {
                    HStack(spacing: 10) {
                        Text(agent.paused ? L10n.Inspector.statePaused : L10n.Inspector.stateRunning)
                            .font(BanditoFont.font(size: 12.5, weight: 500))
                            .foregroundStyle(agent.paused ? Color.Bandito.text2 : Color.Bandito.text)
                        Button(agent.paused ? L10n.Agent.Menu.resume : L10n.Agent.Menu.pause) {
                            change { _ = try await server.setPaused(agentID: agent.id, !agent.paused) }
                        }
                        .banditoButton(.link)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .foregroundStyle(BanditoPalette.peach)
                        .disabled(!PauseActions.available(on: server))
                        .help(PauseActions.available(on: server) ? "" : L10n.Team.pauseUnavailable)
                    }
                }
                InspectorRow(label: L10n.Inspector.runsOn) {
                    Menu {
                        ForEach(RuntimeKind.pickable.filter { $0 != agent.runtime }, id: \.self) { kind in
                            Button(kind.title) { switchRuntime(to: kind) }
                        }
                    } label: {
                        Text(runtimeLine)
                    }
                    .menuStyle(.button)
                    .banditoButton(.link)
                    .fixedSize()
                }
                InspectorRow(label: L10n.Inspector.model) {
                    TextField(L10n.AgentSheet.modelDefault, text: $modelDraft)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 170)
                        .onSubmit(saveModel)
                }
                InspectorRow(label: L10n.AgentSheet.fallbackLabel) {
                    Menu {
                        Button(L10n.AgentSheet.fallbackNone) { setFallback(nil) }
                        ForEach(NewAgentDraft.fallbackOptions(for: agent.runtime), id: \.self) { kind in
                            Button(kind.title) { setFallback(kind) }
                        }
                    } label: {
                        Text(agent.fallbackRuntime?.title ?? L10n.AgentSheet.fallbackNone)
                    }
                    .menuStyle(.button)
                    .banditoButton(.link)
                    .fixedSize()
                }
                InspectorRow(label: L10n.Inspector.approvals) {
                    Menu {
                        ForEach(ApprovalMode.allCases, id: \.self) { mode in
                            Button(mode.title) {
                                change { _ = try await server.updateAgent(agent.id, approvalMode: mode) }
                            }
                        }
                    } label: {
                        Text(agent.approvalMode.title)
                    }
                    .menuStyle(.button)
                    .banditoButton(.link)
                    .fixedSize()
                }
                InspectorRow(label: L10n.Inspector.project) {
                    TextField("", text: $folder)
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                        .onSubmit(saveFolder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Effort.title)
                SegmentedPicker(
                    selection: effort,
                    options: EffortLevels.levels(for: agent.runtime).map { ($0, $0.title) })
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(L10n.Inspector.scheduleHeader)
                    Spacer()
                    Button(L10n.Inspector.addSchedule) { showingNewSchedule = true }
                        .banditoButton(.link)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .foregroundStyle(BanditoPalette.peach)
                }
                if schedules.isEmpty {
                    Text(L10n.Inspector.noSchedules)
                        .font(BanditoFont.font(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.vertical, 6)
                } else {
                    InspectorCard {
                        ForEach(schedules) { schedule in
                            ScheduleRow(schedule: schedule) { enabled in
                                change {
                                    _ = try await server.updateSchedule(schedule.id, enabled: enabled)
                                    await loadSchedules()
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Inspector.instructionsHeader)
                TextEditor(text: $instructions)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .padding(10)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
                HStack {
                    Spacer()
                    Button(L10n.Common.save) {
                        change { _ = try await server.updateAgent(agent.id, systemPrompt: instructions) }
                    }
                    .banditoButton(.quiet())
                    .disabled(instructions == (agent.systemPrompt ?? ""))
                }
            }

            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(BanditoPalette.peach)
            }

            if let error {
                InspectorError(message: error)
            }
        }
        .onChange(of: agent.model, initial: true) { _, model in
            modelDraft = model ?? ""
        }
        .task(id: agent.id) {
            folder = agent.cwd
            instructions = agent.systemPrompt ?? ""
            await loadSchedules()
        }
        .sheet(isPresented: $showingNewSchedule, onDismiss: { Task { await loadSchedules() } }) {
            ScheduleEditor(server: server, agentID: agent.id)
        }
    }

    private var runtimeLine: String {
        let plan = server.usage.first { $0.runtime == agent.runtime.rawValue }?.plan?.label
        return [agent.runtime.title, plan].compactMap { $0 }.joined(separator: " · ")
    }

    private func saveFolder() {
        let path = folder.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path != agent.cwd else { return }
        change { _ = try await server.updateAgent(agent.id, cwd: path) }
    }

    private func loadSchedules() async {
        schedules = (try? await server.schedules(agentId: agent.id)) ?? []
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
        apply(patch)
    }

    private func setFallback(_ kind: RuntimeKind?) {
        if let kind {
            apply(AgentPatch(fallbackRuntime: .set(kind)))
        } else {
            apply(AgentPatch(fallbackRuntime: .clear, fallbackModel: .clear))
        }
    }

    /// An empty field goes back to the runtime's default model.
    private func saveModel() {
        let text = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: FieldChange<String> = text.isEmpty ? .clear : .set(text)
        if text == (agent.model ?? "") { return }
        apply(AgentPatch(model: next))
    }
}

private struct ScheduleRow: View {
    var schedule: Schedule
    var onToggle: (Bool) -> Void
    @State private var enabled: Bool
    
    init(schedule: Schedule, onToggle: @escaping (Bool) -> Void) {
        self.schedule = schedule
        self.onToggle = onToggle
        _enabled = State(initialValue: schedule.enabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BanditoPalette.peach)
                .frame(width: 32, height: 32)
                .background(BanditoPalette.peach.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.cron)
                    .font(BanditoFont.font(size: 12.5, weight: 500, mono: true))
                    .foregroundStyle(Color.Bandito.text)
                Text(schedule.prompt)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                if let next = schedule.nextRunAt {
                    Text(L10n.Inspector.nextRun(time: TeamTime.label(ms: next)))
                        .font(BanditoFont.font(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: enabled) { _, value in
                    if value != schedule.enabled { onToggle(value) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// New schedule: a cron expression and the prompt the agent receives on each run.
private struct ScheduleEditor: View {
    var server: ServerModel
    var agentID: String

    @Environment(\.dismiss) private var dismiss
    @State private var cron = ""
    @State private var prompt = ""
    @State private var error: UserFacingMessage?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Inspector.addSchedule)
                .font(BanditoFont.font(size: 16, weight: 650))
                .foregroundStyle(Color.Bandito.text)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L10n.Inspector.cronLabel)
                TextField("0 9 * * 1-5", text: $cron)
                    .textFieldStyle(.roundedBorder)
                    .font(BanditoFont.font(size: 13, weight: 400, mono: true))
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L10n.Inspector.promptLabel)
                TextEditor(text: $prompt)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.Bandito.line, lineWidth: 1))
            }
            if let error {
                InspectorError(message: error)
            }
            HStack {
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                    .banditoButton(.quiet())
                Button(L10n.Inspector.addSchedule) { add() }
                    .banditoButton(.signal())
                    .disabled(busy || cron.trimmingCharacters(in: .whitespaces).isEmpty
                        || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        busy = true
        error = nil
        Task {
            do {
                _ = try await server.createSchedule(
                    agentId: agentID, cron: cron.trimmingCharacters(in: .whitespaces),
                    tz: TimeZone.current.identifier, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                self.error = UserFacingError.message(for: error)
                busy = false
            }
        }
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

    private var budget: Int { agent.contextBudget ?? ContextUsage.defaultBudget }

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
                    .font(BanditoFont.font(size: 14.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer()
                Text(L10n.Chapter.startedToday)
                    .font(BanditoFont.font(size: 12, weight: 400))
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
            .font(BanditoFont.font(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Chapter.explainer(name: agent.name))
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
        }
        .padding(14)
        .background(Color.Bandito.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
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
                            .font(BanditoFont.font(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        if let badge { Chip(text: badge, tone: .ok) }
                    }
                    Text(description)
                        .font(BanditoFont.font(size: 12, weight: 400))
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

    /// The memory files the agent keeps in its folder. Opening one shows it in the Files mode.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(L10n.Memory.header)
                Spacer()
                Text(agent.homeDir ?? "")
                    .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
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
                            router.openInFiles(item.path, isFile: item.isFile)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.Bandito.text2)
                                    .frame(width: 30, height: 30)
                                    .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(BanditoFont.font(size: 13, weight: 500))
                                        .foregroundStyle(Color.Bandito.text)
                                    Text(item.meta)
                                        .font(BanditoFont.font(size: 11.5, weight: 400))
                                        .foregroundStyle(Color.Bandito.text3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(L10n.Keys.open)
                                    .font(BanditoFont.font(size: 11.5, weight: 600))
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
                    .font(BanditoFont.font(size: 12, weight: 400))
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    Image(systemName: inContainer ? "shippingbox" : "house")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BanditoPalette.peach)
                        .frame(width: 34, height: 34)
                        .background(BanditoPalette.peach.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workplaceTitle)
                            .font(BanditoFont.font(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(workplaceSubtitle)
                            .font(BanditoFont.font(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    Spacer()
                    if workplaces?.supported == true {
                        changeMenu
                    }
                }
                if let error {
                    UserFacingErrorView(message: error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(BanditoFont.font(size: 12, weight: 400))
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
                        .font(BanditoFont.font(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.Bandito.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))

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
    private var changeMenu: some View {
        Menu {
            Button(L10n.Workspace.Shared.title) {
                pendingMove = MoveTarget(id: Workspace.sharedID, name: L10n.Workspace.Shared.title)
            }
            .disabled(!inContainer)
            ForEach(workplaces?.containers ?? []) { container in
                Button(container.name) {
                    pendingMove = MoveTarget(id: container.id, name: container.name)
                }
                .disabled(container.id == agent.workspaceId)
            }
        } label: {
            Text(L10n.Workspace.Location.change)
                .font(BanditoFont.font(size: 12.5, weight: 500))
        }
        .menuStyle(.button)
        .banditoButton(.quiet(size: .regular))
        .fixedSize()
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
                    .font(BanditoFont.font(size: 12.5, weight: 400))
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
                        .font(BanditoFont.font(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    if let plan { Chip(text: plan, tone: .signal) }
                }
                Text(status.installed ? (status.version ?? "") : L10n.Inspector.notInstalled)
                    .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
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
