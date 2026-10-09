import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The new agent sheet (docs/design/NewAgent.dc.html). Identity and runtime on the left; project,
/// workplace, memory and approvals on the right. Creating the agent selects it in the Team mode.
struct NewAgentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    @State private var draft = NewAgentDraft()
    @State private var pickerOpen = false
    @State private var creating = false
    @State private var error: UserFacingMessage?
    /// The server's workplaces, loaded when the sheet opens: what the workplace section can offer.
    @State private var workplaces: WorkspacesModel?
    /// True once the `runtimes.status` request has finished, with or without an answer.
    @State private var runtimesAnswered = false
    /// The workplace made by an earlier attempt to create the agent, reused when the attempt is repeated.
    @State private var preparedWorkplace: PreparedWorkplace?
    @Environment(\.openURL) private var openURL

    private var server: ServerModel? { app.currentServer }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            if server == nil {
                Spacer()
                Text(L10n.AgentSheet.noServer)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer()
            } else {
                // Short windows scroll; the footer with the buttons always stays visible.
                GeometryReader { proxy in
                    ScrollView {
                        Group {
                            if proxy.size.width < Self.narrowWidth {
                                VStack(alignment: .leading, spacing: 26) {
                                    leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                                    rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            } else {
                                HStack(alignment: .top, spacing: 26) {
                                    leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                                    rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            footer
        }
        .frame(minWidth: 640, idealWidth: 1080, maxWidth: .infinity, minHeight: 540, idealHeight: 820, maxHeight: .infinity)
        .background(Color.Bandito.surface2)
        .onAppear {
            if let cwd = router.takeAgentCwd() {
                draft.cwd = cwd
            }
        }
        .task {
            guard let server else { return }
            let loaded = WorkspacesModel(server: server)
            workplaces = loaded
            // Limits are read in the background and their failure is not shown. The runtime status is asked again
            // when the last answer is more than a minute old; until it arrives the cards say "checking".
            Task { _ = try? await server.refreshUsage() }
            let fresh = server.runtimesFetchedAt.map { Date().timeIntervalSince($0) < Self.runtimesMaxAge } ?? false
            if !fresh {
                _ = try? await server.refreshRuntimes()
            }
            runtimesAnswered = true
            await loaded.load()
        }
    }

    /// Below this window width the two columns of the sheet stack one under the other.
    static let narrowWidth: CGFloat = 1000
    /// How old the last `runtimes.status` answer may be when the sheet opens.
    static let runtimesMaxAge: TimeInterval = 60

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            RaccoonAvatar(name: draft.name, color: draft.color, face: draft.face, size: 60, mood: .idle)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.AgentSheet.title)
                    .font(BanditoFont.font(size: 20, weight: 650))
                    .foregroundStyle(Color.Bandito.text)
                HStack(spacing: 7) {
                    ForEach(AvatarColor.allCases, id: \.self) { color in
                        Button {
                            draft.color = color
                        } label: {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(color.color)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if draft.color == color {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(color.color, lineWidth: 1.5)
                                            .frame(width: 28, height: 28)
                                    }
                                }
                        }
                        .banditoButton(.row(cornerRadius: 9, hoverOpacity: 0.08))
                        .accessibilityLabel(colorName(color))
                        .accessibilityAddTraits(draft.color == color ? .isSelected : [])
                    }
                    Rectangle().fill(Color.Bandito.text.opacity(0.1)).frame(width: 1, height: 18).padding(.horizontal, 3)
                    Text(L10n.AgentSheet.faceLabel)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    ForEach(AvatarFace.faces, id: \.self) { face in
                        faceButton(face)
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(AgentTemplate.allCases, id: \.self) { template in
                    Button(template.title) {
                        var next = draft
                        template.apply(to: &next)
                        draft = next
                    }
                }
            } label: {
                Text(L10n.AgentSheet.fromTemplate)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.Bandito.text.opacity(0.04), in: Capsule())
                    .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
            }
            .menuStyle(.button)
            .banditoButton(.row(cornerRadius: 16, hoverOpacity: 0.08))
            .fixedSize()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func faceButton(_ face: AvatarFace) -> some View {
        let selected = draft.face == face
        return Button {
            draft.face = face
        } label: {
            Text(AvatarFace.glyph(face))
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text3)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    selected ? Color.Bandito.text.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
        .accessibilityLabel(faceName(face))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                labeled(L10n.AgentSheet.name) {
                    TextField(defaultName, text: $draft.name)
                        .textFieldStyle(.plain)
                        .modifier(FieldBox())
                }
                labeled(L10n.AgentSheet.role) {
                    TextField(L10n.AgentSheet.rolePlaceholder, text: $draft.role)
                        .textFieldStyle(.plain)
                        .modifier(FieldBox())
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                labeledHeader(L10n.AgentSheet.runtime, hint: L10n.AgentSheet.runtimeHint(server: serverName))
                runtimeGrid
            }

            labeled(L10n.AgentSheet.model) {
                modelField
            }
            labeled(L10n.Effort.title) {
                SegmentedPicker(
                    selection: $draft.effort,
                    options: draft.runtime.supportedEfforts.map { ($0, effortName($0)) })
                    .frame(maxWidth: .infinity)
            }
            Text(effortHint(draft.effort))
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: -6)

            labeled(L10n.AgentSheet.fallbackLabel) {
                fallbackPicker
            }
            if draft.fallbackRuntime != nil {
                labeled(L10n.AgentSheet.model) {
                    TextField(L10n.AgentSheet.modelDefault, text: $draft.fallbackModel)
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .modifier(FieldBox())
                }
            }
            Text(L10n.AgentSheet.fallbackHint)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .offset(y: -8)

            labeled(L10n.AgentSheet.instructions, hint: L10n.AgentSheet.instructionsHint) {
                TextEditor(text: $draft.instructions)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .scrollContentBackground(.hidden)
                    .frame(height: 78)
                    .padding(8)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line))
            }
        }
    }

    private var runtimeGrid: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                ForEach(RuntimeKind.pickable, id: \.self) { kind in
                    runtimeCard(kind, now: context.date)
                }
            }
        }
    }

    /// The fallback runtime: "Don't switch", or one of the other runtimes.
    private var fallbackPicker: some View {
        Menu {
            Button(L10n.AgentSheet.fallbackNone) {
                draft.fallbackRuntime = nil
                draft.fallbackModel = ""
            }
            ForEach(NewAgentDraft.fallbackOptions(for: draft.runtime), id: \.self) { kind in
                Button(runtimeName(kind)) { draft.fallbackRuntime = kind }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13))
                    .foregroundStyle(draft.fallbackRuntime == nil ? Color.Bandito.text3 : Color.Bandito.ok)
                Text(draft.fallbackRuntime.map { runtimeName($0) } ?? L10n.AgentSheet.fallbackNone)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 0)
            }
            .modifier(FieldBox())
        }
        .menuStyle(.button)
        .banditoButton(.row(cornerRadius: 10))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func runtimeCard(_ kind: RuntimeKind, now: Date) -> some View {
        let selected = draft.runtime == kind
        let card = usageCards.first { $0.runtime == kind.rawValue }
        // Only this runtime's card counts: `percentLeft` falls back to all cards when given no runtime.
        let remaining = card.flatMap { UsageCards.percentLeft([$0], runtime: nil) }
        let state = RuntimeCardState.make(
            runtime: kind, status: runtimeStatus(kind), requestDone: runtimesAnswered, remaining: remaining,
            resetsAt: card?.windows.compactMap(\.resetsAt).min(), now: now)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                draft.setRuntime(kind)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(runtimeName(kind))
                            .font(BanditoFont.font(size: 13.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        if let plan = card?.plan {
                            Text(plan)
                                .font(BanditoFont.font(size: 10.5, weight: 600))
                                .foregroundStyle(BanditoPalette.peach)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(BanditoPalette.peach.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 17, height: 17)
                                .background(Color.Bandito.signal, in: Circle())
                        }
                    }
                    HStack(spacing: 6) {
                        if state.kind == .checking {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 10, height: 10)
                        } else {
                            Circle().fill(state.tint).frame(width: 6, height: 6)
                        }
                        Text(state.text)
                            .font(BanditoFont.font(size: 11.5, weight: 400))
                            .foregroundStyle(state.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    if state.showsLimit {
                        UsageBar(fraction: remaining ?? 0, tint: state.barTint, height: 4)
                    }
                    if let command = state.command {
                        Text(L10n.AgentSheet.statusNeedsLoginHint)
                            .font(BanditoFont.font(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                        Text(command)
                            .font(BanditoFont.font(size: 11.5, weight: 500, mono: true))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    if !state.hint.isEmpty {
                        Text(state.hint)
                            .font(BanditoFont.font(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? Color.Bandito.signal.opacity(0.08) : Color.Bandito.text.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? Color.Bandito.signal.opacity(0.5) : Color.Bandito.text.opacity(0.09)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .banditoButton(.row(cornerRadius: 14))
            .accessibilityAddTraits(selected ? .isSelected : [])

            // Outside the card's button: a link inside a button would not be clickable on its own.
            if let url = state.installURL {
                Button(L10n.AgentSheet.installGuide) { openURL(url) }
                    .font(BanditoFont.font(size: 11.5, weight: 500))
                    .banditoButton(.link)
                    .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private var modelField: some View {
        let presets = NewAgentDraft.modelPresets(for: draft.runtime)
        HStack(spacing: 6) {
            TextField(L10n.AgentSheet.modelDefault, text: $draft.model)
                .textFieldStyle(.plain)
                .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text)
            if !presets.isEmpty {
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset) { draft.model = preset }
                    }
                    Divider()
                    Button(L10n.AgentSheet.modelDefault) { draft.model = "" }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .menuStyle(.button)
                .banditoButton(.row(cornerRadius: 5, hoverOpacity: 0.08))
                .fixedSize()
            }
        }
        .modifier(FieldBox())
        .help(presets.isEmpty ? L10n.AgentSheet.modelFreeHint : presets.joined(separator: ", "))
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled(L10n.AgentSheet.folder, hint: L10n.AgentSheet.folderHint) {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(BanditoPalette.peach)
                    Text(draft.cwd.isEmpty ? L10n.AgentSheet.noFolder : draft.cwd)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(draft.cwd.isEmpty ? Color.Bandito.text3 : Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    Button(L10n.AgentSheet.chooseFolder) { pickerOpen.toggle() }
                        .banditoButton(.quiet(size: .regular))
                        .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                            if let server {
                                FolderPicker(server: server, selection: $draft.cwd) { pickerOpen = false }
                            }
                        }
                }
                .modifier(FieldBox())
            }

            workplaceSection

            labeled(L10n.AgentSheet.memory, hint: nil) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(memoryName(draft.memory))
                            .font(BanditoFont.font(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text)
                        Spacer(minLength: 0)
                        Menu {
                            ForEach(MemoryMode.allCases, id: \.self) { mode in
                                Button(memoryName(mode)) { draft.memory = mode }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.Bandito.text3)
                        }
                        .menuStyle(.button)
                        .banditoButton(.row(cornerRadius: 5, hoverOpacity: 0.08))
                        .fixedSize()
                    }
                    Text(L10n.AgentSheet.memoryAuto)
                        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .modifier(FieldBox())
                Text(L10n.AgentSheet.memoryHint)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }

            labeled(L10n.AgentSheet.askAbout, hint: nil) {
                SegmentedPicker(
                    selection: $draft.approval,
                    options: ApprovalChoice.allCases.map { ($0, $0.title) })
            }
            Text(L10n.AgentSheet.approvalsHint(path: draft.cwd.isEmpty ? "~" : draft.cwd))
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: -8)

            labeled(L10n.AgentSheet.tools, hint: nil) {
                FlowTags(tags: toolTags)
            }
        }
    }

    // MARK: Workplace

    /// Shared server or a separate workplace. A separate one is an existing container or a new one (name, defaults).
    private var workplaceSection: some View {
        let available = workplaces?.canCreateSeparate ?? false
        let supported = workplaces?.supported ?? false
        return VStack(alignment: .leading, spacing: 9) {
            labeledHeader(L10n.AgentSheet.workplace, hint: L10n.AgentSheet.workplaceHint)
            SegmentedPicker(
                selection: Binding(get: { draft.workplace.mode }, set: { setMode($0) }),
                options: [
                    (WorkplaceChoice.Mode.shared, L10n.AgentSheet.workplaceShared),
                    (WorkplaceChoice.Mode.separate, L10n.AgentSheet.workplaceSeparate),
                ])
            if draft.workplace.mode == .shared {
                Text(L10n.AgentSheet.workplaceSharedText)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else if available {
                separateFields
            }
            if supported && !available {
                Text(L10n.Workspace.Choice.dockerNeeded)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var separateFields: some View {
        let containers = workplaces?.containers ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workplaceName(containers))
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 0)
                Menu {
                    ForEach(containers) { container in
                        Button(container.name) { draft.workplace = .existing(container.id) }
                    }
                    if !containers.isEmpty {
                        Divider()
                    }
                    Button(L10n.Workspace.Choice.newOne) { draft.workplace = .new }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .menuStyle(.button)
                .banditoButton(.row(cornerRadius: 5, hoverOpacity: 0.08))
                .fixedSize()
            }
            .modifier(FieldBox())
            if draft.workplace == .new {
                TextField(L10n.Workspace.Create.name, text: $draft.newWorkplace.name)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .modifier(FieldBox())
                Text(L10n.Workspace.Draft.defaults(limits: draft.newWorkplace.limitsText))
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(L10n.Workspace.Choice.isolation)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Workspace.Choice.lost)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Switching to "separate" picks the first container, or a new one when there is none yet.
    private func setMode(_ mode: WorkplaceChoice.Mode) {
        guard mode == .shared || (workplaces?.canCreateSeparate ?? false) else { return }
        switch mode {
        case .shared:
            draft.workplace = .shared
        case .separate:
            if draft.workplace == .shared {
                if let first = workplaces?.containers.first {
                    draft.workplace = .existing(first.id)
                } else {
                    draft.workplace = .new
                }
            }
        }
    }

    private func workplaceName(_ containers: [Workspace]) -> String {
        switch draft.workplace {
        case .shared, .new: L10n.Workspace.Choice.newOne
        case .existing(let id): containers.first { $0.id == id }?.name ?? L10n.Workspace.Choice.newOne
        }
    }

    private var toolTags: [FlowTags.Tag] {
        [
            .init(text: "✓ " + L10n.AgentSheet.toolTerminal, on: true),
            .init(text: "✓ " + L10n.AgentSheet.toolFiles, on: true),
            .init(text: "✓ " + L10n.AgentSheet.toolBrowser, on: true),
            .init(text: "✓ " + L10n.AgentSheet.toolTeam, on: true),
            .init(text: "+ " + L10n.AgentSheet.toolScreen, on: false),
        ]
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let error {
                UserFacingErrorView(message: error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Text(blockerText ?? L10n.AgentSheet.changeLater)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(blockerText == nil ? Color.Bandito.text3 : BanditoPalette.peach)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.AgentSheet.cancel) { router.sheet = nil }
                    .banditoButton(.quiet(size: .regular))
                Button(L10n.AgentSheet.create(name: defaultName)) { create() }
                    .banditoButton(.signal(size: .regular))
                    .disabled(blocker != nil || creating || server == nil)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Color.Bandito.bg.opacity(0.4))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
        }
    }

    // MARK: Actions

    private func create() {
        guard let server, draft.canCreate else { return }
        creating = true
        error = nil
        Task {
            do {
                let workspaceID = try await workplaceForCreate(on: server)
                let agent = try await server.createAgent(
                    draft.makeNewAgent(workspaceID: workspaceID, existingNames: agentNames))
                var recent = RecentFolders.load(serverID: server.id.uuidString)
                recent.remember(agent.cwd)
                recent.save(serverID: server.id.uuidString)
                router.selectedAgentID = agent.id
                router.select(mode: .team)
                router.sheet = nil
            } catch {
                self.error = WorkspaceText.message(for: error)
                creating = false
            }
        }
    }

    /// The workplace id for `agents.create`. A new container is made once: when creating the agent fails and the
    /// person presses Create again, the container made by the first attempt is used, not a second one.
    private func workplaceForCreate(on server: ServerModel) async throws -> String? {
        if let made = preparedWorkplace, made.choice == draft.workplace, made.form == draft.newWorkplace {
            return made.id
        }
        let id = try await WorkplaceCreation.prepare(draft.workplace, new: draft.newWorkplace, on: server)
        preparedWorkplace = PreparedWorkplace(choice: draft.workplace, form: draft.newWorkplace, id: id)
        return id
    }

    // MARK: Helpers

    /// The name the agent gets when the field is empty: shown as the field's placeholder and on the button.
    private var defaultName: String {
        draft.resolvedName(existing: agentNames)
    }

    private var agentNames: [String] {
        server?.agents.map(\.name) ?? []
    }

    /// Why "Create" is off right now, in words. Nil when it can be pressed.
    private var blocker: CreateBlocker? {
        draft.createBlocker(status: runtimeStatus(draft.runtime))
    }

    private var blockerText: String? {
        switch blocker {
        case nil: nil
        case .runtimeMissing(let kind): L10n.AgentSheet.runtimeMissing(runtime: runtimeName(kind), server: serverName)
        case .runtimeLogin(let kind, let command):
            L10n.AgentSheet.runtimeLogin(runtime: runtimeName(kind), server: serverName, command: command)
        case .folder: L10n.AgentSheet.createBlockedFolder
        case .workplace: L10n.AgentSheet.createBlockedWorkplace
        }
    }

    private var serverName: String {
        server?.config.name ?? ""
    }

    private var usageCards: [UsageCard] {
        UsageCards.snapshot(server: server, demo: nil).cards
    }

    private func runtimeStatus(_ kind: RuntimeKind) -> RuntimeStatus? {
        server?.runtimes.first { $0.kind == kind }
    }

    private func labeled<Content: View>(
        _ title: String, hint: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledHeader(title, hint: hint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledHeader(_ title: String, hint: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            if let hint, !hint.isEmpty {
                Text("· " + hint)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
        }
    }

    private func runtimeName(_ kind: RuntimeKind) -> String {
        switch kind {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .api: L10n.Runtime.api
        }
    }

    private func effortName(_ effort: Effort) -> String {
        switch effort {
        case .low: L10n.Effort.low
        case .medium: L10n.Effort.medium
        case .high: L10n.Effort.high
        case .xhigh: L10n.Effort.xhigh
        case .max: L10n.Effort.max
        }
    }

    private func effortHint(_ effort: Effort) -> String {
        switch effort {
        case .low: L10n.AgentSheet.effortHintLow
        case .medium: L10n.AgentSheet.effortHintMedium
        case .high: L10n.AgentSheet.effortHintHigh
        case .xhigh: L10n.AgentSheet.effortHintXhigh
        case .max: L10n.AgentSheet.effortHintMax
        }
    }

    private func memoryName(_ mode: MemoryMode) -> String {
        switch mode {
        case .smart: L10n.Memory.smartChapters
        case .daily: L10n.Memory.daily
        case .full: L10n.Memory.full
        }
    }

    private func colorName(_ color: AvatarColor) -> String {
        switch color {
        case .peach: L10n.AgentSheet.colorPeach
        case .sky: L10n.AgentSheet.colorSky
        case .sage: L10n.AgentSheet.colorSage
        case .rose: L10n.AgentSheet.colorRose
        case .lilac: L10n.AgentSheet.colorLilac
        case .cream: L10n.AgentSheet.colorCream
        }
    }

    private func faceName(_ face: AvatarFace) -> String {
        switch face {
        case .auto, .chevronDash: L10n.AgentSheet.faceSquint
        case .dots: L10n.AgentSheet.faceDots
        case .carets: L10n.AgentSheet.faceSmile
        }
    }
}

extension RuntimeKind {
    /// The runtimes a new agent can pick. The API-key runtime is not in this build, so it has no card.
    static let pickable: [RuntimeKind] = [.claude, .codex, .grok]
}

extension AvatarFace {
    /// The faces the new agent sheet offers, in the design's order.
    static let faces: [AvatarFace] = [.chevronDash, .dots, .carets]

    /// The text drawn for a face in the picker.
    static func glyph(_ face: AvatarFace) -> String {
        switch face {
        case .auto, .chevronDash: "> –"
        case .dots: "• •"
        case .carets: "^ ^"
        }
    }
}

/// Where to read how to install each CLI, for a runtime the server does not have.
enum RuntimeInstallLinks {
    static func url(for runtime: RuntimeKind) -> URL? {
        switch runtime {
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
        case .codex: URL(string: "https://developers.openai.com/codex/cli")
        case .grok: URL(string: "https://x.ai/cli")
        case .api: nil
        }
    }
}

/// What a runtime card shows: text, tint, the hint line and whether the limit bar is drawn. Pure, so the rules are
/// easy to read and test.
struct RuntimeCardState: Equatable {
    enum Kind: Equatable {
        /// `runtimes.status` is on its way.
        case checking
        /// The status request finished without an answer for this runtime.
        case unknown
        case notInstalled
        case needsLogin
        /// Installed and signed in; no limits are known yet (Claude reports them after the first reply).
        case ready
        case limits
        case exhausted
    }

    let kind: Kind
    let text: String
    /// The reset countdown, or empty.
    let hint: String
    let tint: Color
    let barTint: Color
    /// Where to read how to install the CLI. Only for a runtime that is not installed.
    let installURL: URL?
    /// The command that signs the person in, shown in monospace. Only when the runtime is not signed in.
    var command: String?

    var showsLimit: Bool { kind == .limits || kind == .exhausted }

    static func make(
        runtime: RuntimeKind, status: RuntimeStatus?, requestDone: Bool, remaining: Double?, resetsAt: Date?,
        now: Date
    ) -> RuntimeCardState {
        guard let status else {
            if requestDone {
                return RuntimeCardState(
                    kind: .unknown, text: L10n.AgentSheet.statusUnknown, hint: "", tint: Color.Bandito.text3,
                    barTint: Color.Bandito.text3, installURL: nil)
            }
            return RuntimeCardState(
                kind: .checking, text: L10n.AgentSheet.statusChecking, hint: "", tint: Color.Bandito.text3,
                barTint: Color.Bandito.text3, installURL: nil)
        }
        if !status.installed {
            return RuntimeCardState(
                kind: .notInstalled, text: L10n.AgentSheet.statusNotInstalled, hint: "", tint: Color.Bandito.danger,
                barTint: Color.Bandito.danger, installURL: RuntimeInstallLinks.url(for: runtime))
        }
        if status.loggedIn == false {
            return RuntimeCardState(
                kind: .needsLogin, text: L10n.AgentSheet.statusNeedsLogin, hint: "", tint: BanditoPalette.peach,
                barTint: BanditoPalette.peach, installURL: nil,
                command: LoginCommand.arguments(for: runtime).joined(separator: " "))
        }
        guard let remaining else {
            let text = versionLabel(status.version).map { L10n.AgentSheet.statusReadyVersion(version: $0) }
                ?? L10n.AgentSheet.statusReady
            return RuntimeCardState(
                kind: .ready, text: text, hint: "", tint: Color.Bandito.ok, barTint: Color.Bandito.ok,
                installURL: nil)
        }
        let percent = Int((remaining * 100).rounded())
        let reset = resetsAt.map { Countdown.text(to: $0, now: now) } ?? ""
        if remaining <= 0 {
            let again = resetsAt.map { Countdown.text(to: $0, now: now, exhausted: true) } ?? ""
            return RuntimeCardState(
                kind: .exhausted, text: L10n.AgentSheet.statusExhausted(time: again), hint: "",
                tint: Color.Bandito.danger, barTint: Color.Bandito.danger, installURL: nil)
        }
        let tint = remaining < 0.25 ? BanditoPalette.peach : Color.Bandito.ok
        return RuntimeCardState(
            kind: .limits, text: L10n.AgentSheet.statusSignedIn(percent: "\(percent)"),
            hint: reset.isEmpty ? "" : L10n.AgentSheet.resetsIn(time: reset), tint: tint,
            barTint: remaining < 0.25 ? BanditoPalette.peach : Color.Bandito.ok, installURL: nil)
    }

    /// "v2.0.5" from a CLI's version line such as "2.0.5 (Claude Code)": the first number with a dot in it.
    static func versionLabel(_ raw: String?) -> String? {
        guard let raw, let match = raw.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else {
            return nil
        }
        return "v" + raw[match]
    }
}

/// The workplace that an attempt to create an agent prepared, with the choice and form it was made from.
struct PreparedWorkplace: Equatable {
    let choice: WorkplaceChoice
    let form: NewWorkplaceDraft
    /// The container's id; nil for the shared server.
    let id: String?
}

/// A rounded field surface used by the sheet's inputs.
private struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(BanditoFont.font(size: 13.5, weight: 400))
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line))
    }
}

/// Wrapping row of informative tags ("What it may do"). Whole chips move to the next line; a chip's text never wraps.
private struct FlowTags: View {
    struct Tag: Identifiable {
        let text: String
        let on: Bool
        var id: String { text }
    }

    let tags: [Tag]

    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags) { tag in
                Text(tag.text)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(tag.on ? Color.Bandito.text : Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        tag.on ? Color.Bandito.text.opacity(0.07) : Color.clear,
                        in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            tag.on ? Color.Bandito.text.opacity(0.12) : Color.Bandito.text.opacity(0.14),
                            style: StrokeStyle(lineWidth: 1, dash: tag.on ? [] : [3, 2])))
            }
        }
    }
}

/// Lays subviews out left to right and moves a whole subview to the next line when it does not fit.
private struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
