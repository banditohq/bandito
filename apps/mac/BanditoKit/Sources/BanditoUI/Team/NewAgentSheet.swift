import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// The new agent sheet (docs/design/NewAgent.dc.html). Identity and runtime on the left; project,
/// workplace, memory and approvals on the right. Creating the agent selects it in the Team mode.
struct NewAgentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    @State private var draft = NewAgentDraft()
    @State private var pickerOpen = false
    /// The "Advanced" block (effort, fallback) is folded until the person opens it.
    @State private var advancedOpen = false
    @State private var creating = false
    @State private var error: UserFacingMessage?
    /// The agent made by a create that then failed on its picture; the next press only saves the picture.
    @State private var createdAgent: Agent?
    /// The draft's picture, decoded for the header and the editor.
    @State private var previewPicture: CGImage?
    @State private var editingAvatar = false
    /// What the avatar editor keeps while its popover is closed (a picture read from disk): choosing a file closes it.
    @State private var avatarEditor = AvatarEditorModel()
    /// The server's workplaces, loaded when the sheet opens: what the workplace section can offer.
    @State private var workplaces: WorkspacesModel?
    /// The server's integrations, for the "Integrations" choice. Empty when the server has none.
    @State private var integrations: [Integration] = []
    /// True once the `runtimes.status` request has finished, with or without an answer.
    @State private var runtimesAnswered = false
    /// The workplace made by an earlier attempt to create the agent, reused when the attempt is repeated.
    @State private var preparedWorkplace: PreparedWorkplace?
    @Environment(\.openURL) private var openURL

    private var server: ServerModel? { app.currentServer }

    /// Asks the server for its model lists again (the model picker's "Повторить").
    private var retryModels: (() -> Void)? {
        guard let server else { return nil }
        return { Task { try? await server.refreshRuntimeModels(refresh: true) } }
    }

    /// Updates this Mac's server to the app's daemon (the model picker's "Обновить"). Only for this Mac's own server.
    private var updateThisMac: (() -> Void)? {
        guard let server, server.isThisMacServer else { return nil }
        return { Task { await app.localUpgrade.upgradeByRequest(server) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            if server == nil {
                Spacer()
                Text(L10n.AgentSheet.noServer)
                    .font(BanditoFont.text(size: 13, weight: 400))
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
            if let template = router.takePendingTemplate() {
                template.apply(to: &draft)
            }
        }
        // A server that takes an agent without a folder lets the agent work in its own folder. Follows `server.info`,
        // so a daemon that answers late (or is updated while the sheet is open) is picked up.
        .onChange(of: server?.supports("agent_own_folder") ?? false, initial: true) { _, optional in
            draft.folderOptional = optional
        }
        // The containers are loaded once the sheet opens. A chosen container that is gone by then becomes a new one.
        // A failed load keeps the choice: an empty list is not proof that the container is gone.
        .onChange(of: workplaces?.loading) { _, loading in
            guard loading == false, let workplaces, workplaces.errorText == nil else { return }
            draft.workplace = SelectChoices.workplace(draft.workplace, containerIDs: workplaces.containers.map(\.id))
        }
        .task {
            guard let server else { return }
            if server.supports("integrations") {
                integrations = (try? await server.integrations()) ?? []
            }
            let loaded = WorkspacesModel(server: server)
            workplaces = loaded
            // The model lists are asked in the background; until they come the model field says "loading".
            Task { _ = try? await server.refreshRuntimeModels() }
            // Limits are read in the background and their failure is not shown. The runtime status is asked again
            // when the last answer is more than a minute old; until it arrives the cards say "checking".
            Task { await server.refreshUsageIfStale() }
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

    /// The avatar in the header; a click opens the editor. Its look and picture go into the draft.
    private var avatarButton: some View {
        Button {
            editingAvatar = true
        } label: {
            AvatarArtView(name: draft.name, look: draftLook.wrappedValue, picture: previewPicture, size: 60)
        }
        .banditoButton(.row(cornerRadius: 16, hoverOpacity: 0.06))
        .help(L10n.Inspector.Avatar.help)
        .popover(isPresented: $editingAvatar, arrowEdge: .bottom) {
            AvatarEditor(
                name: draft.name, look: draftLook, model: avatarEditor, picture: previewPicture,
                pictureSupported: server?.supports("avatar_pictures") == true,
                onSetPicture: { data in
                    draft.picture = data
                    previewPicture = await AvatarPictures.decodeOffMain(data)
                },
                onRemovePicture: {
                    draft.picture = nil
                    previewPicture = nil
                })
        }
        // The file panel closed the popover; the picture it gave is framed in the editor shown again.
        .onChange(of: avatarEditor.loadedCount) { _, _ in editingAvatar = true }
        .onChange(of: draft.picture, initial: true) { _, data in
            Task {
                guard let data else {
                    previewPicture = nil
                    return
                }
                previewPicture = await AvatarPictures.decodeOffMain(data)
            }
        }
    }

    /// The draft's look as the editor edits it.
    private var draftLook: Binding<AvatarLook> {
        Binding(
            get: {
                AvatarLook(palette: draft.color, customHex: draft.customHex, face: draft.face, emoji: draft.emoji)
            },
            set: { look in
                draft.color = look.palette
                draft.customHex = look.customHex
                draft.face = look.face
                draft.emoji = look.emoji
            })
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            avatarButton
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.AgentSheet.title)
                    .font(BanditoFont.display(size: 18.5, weight: 600))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.Bandito.text)
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
                    .font(BanditoFont.text(size: 12.5, weight: 400))
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

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                labeled(L10n.AgentSheet.name) {
                    TextField(defaultName, text: $draft.name)
                        .banditoField()
                }
                labeled(L10n.AgentSheet.role) {
                    TextField(L10n.AgentSheet.rolePlaceholder, text: $draft.role)
                        .banditoField()
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                labeledHeader(L10n.AgentSheet.runtime, hint: L10n.AgentSheet.runtimeHint(server: serverName))
                runtimeGrid
            }

            labeled(L10n.AgentSheet.model) {
                ModelPicker(
                    runtime: draft.runtime, selection: $draft.model,
                    models: server?.runtimeModels[draft.runtime.rawValue],
                    status: server?.runtimeModelsStatus ?? .unknown,
                    onRetry: retryModels, onUpdate: updateThisMac)
            }
            advancedSection

            labeled(L10n.AgentSheet.instructions, hint: L10n.AgentSheet.instructionsHint) {
                // A vertical TextField, not TextEditor: a TextEditor is a scroll view of its own, so the wheel over it
                // scrolls it instead of the sheet. The field grows with the text (4 to 12 lines); Return adds a line.
                TextField(L10n.AgentSheet.instructionsPlaceholder, text: $draft.instructions, axis: .vertical)
                    .banditoField()
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(4...12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            labeled(L10n.Capability.title) {
                CapabilityChips(enabled: $draft.capabilities)
            }

            if !integrations.isEmpty {
                labeled(L10n.Integrations.title) {
                    AgentIntegrationsPicker(integrations: integrations, choice: $draft.integrations)
                }
            }
        }
        // A model that takes fewer levels (or a list that arrives late) moves the effort to the nearest level it takes.
        .onChange(of: effortLevels) { _, levels in
            if let nearest = draft.effort.nearest(in: levels) {
                draft.effort = nearest
            }
        }
    }

    // MARK: Advanced

    /// "Effort" and "If the limit runs out" live under one folded block; the model above is what most people change.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                    Spacer(minLength: 8)
                    if !advancedOpen, let summary = advancedSummary {
                        Text(summary)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 8))
            .accessibilityValue(advancedOpen ? L10n.AgentSheet.advancedExpanded : L10n.AgentSheet.advancedCollapsed)

            if advancedOpen {
                VStack(alignment: .leading, spacing: 14) {
                    if effortLevels.isEmpty {
                        Text(L10n.ModelPicker.noEffort)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    } else {
                        labeled(L10n.Effort.title) {
                            SegmentedPicker(
                                selection: $draft.effort,
                                options: effortLevels.map { ($0, effortName($0)) })
                                .frame(maxWidth: .infinity)
                        }
                        Text(L10n.AgentSheet.effortCaption)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(y: -6)
                    }

                    labeled(L10n.AgentSheet.fallbackLabel) {
                        fallbackPicker
                    }
                    if let fallback = draft.fallbackRuntime {
                        labeled(L10n.AgentSheet.model) {
                            ModelPicker(
                                runtime: fallback, selection: $draft.fallbackModel,
                                models: server?.runtimeModels[fallback.rawValue],
                                status: server?.runtimeModelsStatus ?? .unknown,
                                onRetry: retryModels, onUpdate: updateThisMac)
                        }
                    }
                    Text(L10n.AgentSheet.fallbackHint)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -8)
                }
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
        .banditoAnimation(BanditoMotion.ease, value: advancedOpen)
        .banditoAnimation(BanditoMotion.ease, value: draft.fallbackRuntime)
    }

    /// What was changed from the defaults, for the folded block: "Effort: High · Fallback: Codex". Nil when nothing was.
    private var advancedSummary: String? {
        var parts: [String] = []
        if !effortLevels.isEmpty, draft.effort != NewAgentDraft().effort {
            parts.append(L10n.AgentSheet.advancedEffort(level: effortName(draft.effort)))
        }
        if let fallback = draft.fallbackRuntime {
            parts.append(L10n.AgentSheet.advancedFallback(runtime: runtimeName(fallback)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The levels the effort control offers: those of the chosen model when its list says, else the runtime's. Empty
    /// when the model takes no effort at all.
    private var effortLevels: [Effort] {
        RuntimeModelDisplay.effortLevels(
            modelID: draft.model, runtime: draft.runtime, lists: server?.runtimeModels ?? [:])
    }

    private var runtimeGrid: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let rows = RuntimeCardRows.pairs(RuntimeKind.pickable)
            // Each row is a pair of cards that share one height. An odd last card keeps the left half of the row.
            Grid(alignment: .top, horizontalSpacing: 9, verticalSpacing: 9) {
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(rows[index], id: \.self) { kind in
                            runtimeCard(kind, now: context.date)
                        }
                        if rows[index].count == 1 {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    /// The fallback runtime: "Don't switch", or one of the other runtimes, each with its status as the subtitle.
    private var fallbackPicker: some View {
        BanditoSelect(
            selection: fallbackBinding, sections: [SelectSection(options: fallbackChoices)],
            label: L10n.AgentSheet.fallbackLabel, placeholder: L10n.AgentSheet.fallbackNone)
    }

    private var fallbackBinding: Binding<RuntimeKind?> {
        Binding(
            get: { draft.fallbackRuntime },
            set: { draft.setFallbackRuntime($0, lists: server?.runtimeModels ?? [:]) })
    }

    private var fallbackChoices: [SelectOption<RuntimeKind?>] {
        let none = SelectOption<RuntimeKind?>(value: nil, title: L10n.AgentSheet.fallbackNone, icon: "minus")
        let runtimes = NewAgentDraft.fallbackOptions(for: draft.runtime).map { kind in
            SelectOption<RuntimeKind?>(
                value: kind, title: runtimeName(kind), subtitle: runtimeStatusText(kind), icon: "arrow.right")
        }
        return [none] + runtimes
    }

    /// A runtime's state as its card shows it ("Ready · v2.0", "Not installed"), for the fallback's choices.
    private func runtimeStatusText(_ kind: RuntimeKind) -> String {
        let now = Date()
        let card = usageCards.first { $0.runtime == kind.rawValue }
        let remaining = card.flatMap { UsageCards.percentLeft([$0], runtime: nil) }
        return RuntimeCardState.make(
            runtime: kind, status: runtimeStatus(kind), requestDone: runtimesAnswered, remaining: remaining,
            exhaustedUntil: card.flatMap { UsageCards.exhaustedReset($0.windows, now: now) }, now: now
        ).text
    }

    private func runtimeCard(_ kind: RuntimeKind, now: Date) -> some View {
        let selected = draft.runtime == kind
        let card = usageCards.first { $0.runtime == kind.rawValue }
        let lists = server?.runtimeModels ?? [:]
        // Only this runtime's card counts: `percentLeft` falls back to all cards when given no runtime.
        let remaining = card.flatMap { UsageCards.percentLeft([$0], runtime: nil) }
        let state = RuntimeCardState.make(
            runtime: kind, status: runtimeStatus(kind), requestDone: runtimesAnswered, remaining: remaining,
            exhaustedUntil: card.flatMap { UsageCards.exhaustedReset($0.windows, now: now) }, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                draft.setRuntime(kind, lists: lists)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(runtimeName(kind))
                            .font(BanditoFont.text(size: 13.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        if let plan = card?.plan {
                            Text(plan)
                                .font(BanditoFont.text(size: 10.5, weight: 600))
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
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(state.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    if state.showsLimit, let nearest = card?.windows.max(by: { $0.used < $1.used }) {
                        // One thin bar for the limit that runs out first; every window is in the tooltip.
                        let used = Int((nearest.used * 100).rounded())
                        UsageBar(fraction: nearest.used, tint: UsageLevel(usedPercent: used).color, height: 3)
                        Text(
                            [L10n.Usage.used(percent: "\(used)%"), resetCaption(nearest, now: now)]
                                .compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(BanditoFont.text(size: 11, weight: 400))
                        .monospacedDigit()
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    }
                    if let command = state.command {
                        Text(L10n.AgentSheet.statusNeedsLoginHint)
                            .font(BanditoFont.text(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                        Text(command)
                            .font(BanditoFont.mono(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(
                    selected ? Color.Bandito.signal.opacity(0.08) : Color.Bandito.text.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? Color.Bandito.signal.opacity(0.5) : Color.Bandito.text.opacity(0.09)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .banditoButton(.row(cornerRadius: 14))
            .help(limitTooltip(card?.windows ?? [], state: state, now: now))
            .accessibilityAddTraits(selected ? .isSelected : [])

            // Outside the card's button: a link inside a button would not be clickable on its own.
            if let url = state.installURL {
                Button(L10n.AgentSheet.installGuide) { openURL(url) }
                    .font(BanditoFont.text(size: 11.5, weight: 500))
                    .banditoButton(.link)
                    .padding(.leading, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The card's tooltip: the status, then every limit window with how much is used and when it resets.
    private func limitTooltip(_ windows: [UsageWindowLine], state: RuntimeCardState, now: Date) -> String {
        var lines = [state.text]
        for line in windows {
            var text = "\(line.label): \(L10n.Usage.used(percent: "\(Int((line.used * 100).rounded()))%"))"
            if let caption = resetCaption(line, now: now) { text += " · " + caption }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    /// "Resets in 2 h 48 min", or "again in 5:48:12" while the window is used up. `nil` without a reset time.
    private func resetCaption(_ line: UsageWindowLine, now: Date) -> String? {
        guard let resetsAt = line.resetsAt else { return nil }
        return "\(L10n.AgentSheet.windowResets) \(Countdown.text(to: resetsAt, now: now))"
    }

    /// The project folder as one field: a click anywhere on it opens the folder picker. The clear icon shows only
    /// when a folder is chosen and the server takes an agent without one (the agent then works in its own folder).
    private var folderField: some View {
        HStack(spacing: 0) {
            Button {
                pickerOpen.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(BanditoPalette.peach)
                    if draft.cwd.isEmpty {
                        Text(L10n.AgentSheet.noFolder)
                            .font(BanditoFont.text(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                    } else {
                        Text(draft.cwd)
                            .font(BanditoFont.mono(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 12))
            .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                if let server {
                    FolderPicker(server: server, selection: $draft.cwd) { pickerOpen = false }
                }
            }
            .accessibilityLabel(L10n.AgentSheet.folderAccessibility)
            .accessibilityValue(draft.cwd)

            if draft.folderOptional && !draft.cwd.isEmpty {
                Button {
                    draft.cwd = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .banditoButton(.icon(size: 26, label: L10n.AgentSheet.folderClear))
                .help(L10n.AgentSheet.folderClear)
            }
        }
        .modifier(FieldBox())
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled(L10n.AgentSheet.folder, hint: L10n.AgentSheet.folderHint) {
                folderField
            }

            if draft.folderOptional && draft.cwd.isEmpty {
                Text(L10n.AgentSheet.ownFolderHint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -8)
            }

            workplaceSection

            labeled(L10n.AgentSheet.memory, hint: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    BanditoSelect(
                        selection: $draft.memory, sections: memorySections, label: L10n.AgentSheet.memory,
                        placeholder: memoryName(draft.memory),
                        // The field shows only the mode's name; the description is for the panel.
                        field: { option in SelectFieldView(option: option?.titleOnly, placeholder: "") },
                        footer: { _ in EmptyView() })
                    Text(L10n.AgentSheet.memoryAuto)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.leading, 4)
                }
                Text(L10n.AgentSheet.memoryHint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }

            labeled(L10n.AgentSheet.askAbout, hint: nil) {
                SegmentedPicker(
                    selection: $draft.approval,
                    options: ApprovalChoice.allCases.map { ($0, $0.title) })
            }
            Text(L10n.AgentSheet.approvalsHint(path: draft.cwd.isEmpty ? "~" : draft.cwd))
                .font(BanditoFont.text(size: 12, weight: 400))
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
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else if available {
                separateFields
            }
            if supported && !available {
                Text(L10n.Workspace.Choice.dockerNeeded)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var separateFields: some View {
        let containers = workplaces?.containers ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if containers.isEmpty {
                // Nothing to choose from: the place is the new one, shown as text.
                Text(workplaceName(containers))
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(FieldBox())
            } else {
                BanditoSelect(
                    selection: Binding(get: { existingWorkplaceID }, set: { id in
                        if let id { draft.workplace = .existing(id) }
                    }),
                    sections: [SelectSection(options: containers.map { SelectOption<String?>(value: $0.id, title: $0.name) })],
                    label: L10n.AgentSheet.workplace, placeholder: L10n.Workspace.Choice.newOne,
                    footer: { close in
                        // A new place is not a container: it sits under the list, after a divider.
                        VStack(alignment: .leading, spacing: 0) {
                            Divider().padding(.vertical, 4)
                            Button {
                                draft.workplace = .new
                                close()
                            } label: {
                                Text(L10n.Workspace.Choice.newOne)
                                    .font(BanditoFont.text(size: 13, weight: 500))
                                    .foregroundStyle(Color.Bandito.text)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .banditoButton(.row(cornerRadius: 9))
                        }
                    })
            }
            if draft.workplace == .new {
                TextField(L10n.Workspace.Create.name, text: $draft.newWorkplace.name)
                    .banditoField()
                    .font(BanditoFont.text(size: 13.5, weight: 400))
                Text(L10n.Workspace.Draft.defaults(limits: draft.newWorkplace.limitsText))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(L10n.Workspace.Choice.isolation)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Workspace.Choice.lost)
                .font(BanditoFont.text(size: 12, weight: 400))
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

    /// The id of the existing container the draft points at; nil for the shared server or a new container.
    private var existingWorkplaceID: String? {
        if case .existing(let id) = draft.workplace { return id }
        return nil
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
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(blockerText == nil ? Color.Bandito.text3 : BanditoPalette.peach)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.AgentSheet.cancel) { router.sheet = nil }
                    .banditoButton(.quiet(size: .regular))
                Button(L10n.AgentSheet.create) { create() }
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
                // A picture that failed to save on the first try retries alone: the agent exists already.
                let agent: Agent
                if let made = createdAgent {
                    agent = made
                } else {
                    let workspaceID = try await workplaceForCreate(on: server)
                    // Only integrations the server still has are sent with the new agent.
                    draft.integrations = draft.integrations.limited(to: Set(integrations.map(\.id)))
                    agent = try await server.createAgent(
                        draft.makeNewAgent(
                            workspaceID: workspaceID, existingNames: agentNames, lists: server.runtimeModels))
                    createdAgent = agent
                    // Only a folder the person chose is a recent project folder; an agent's own folder is not.
                    if !draft.cwd.isEmpty {
                        var recent = RecentFolders.load(serverID: server.id.uuidString)
                        recent.remember(agent.cwd)
                        recent.save(serverID: server.id.uuidString)
                    }
                }
                if let picture = draft.picture {
                    do {
                        try await server.setAgentAvatarImage(agent.id, picture)
                    } catch {
                        self.error = UserFacingMessage(text: L10n.AgentSheet.pictureFailed)
                        creating = false
                        return
                    }
                }
                router.selectAgent(agent.id, on: server)
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
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            if let hint, !hint.isEmpty {
                Text("· " + hint)
                    .font(BanditoFont.text(size: 12, weight: 400))
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

    private var memorySections: [SelectSection<MemoryMode>] {
        [
            SelectSection(
                options: MemoryMode.allCases.map { mode in
                    SelectOption(value: mode, title: memoryName(mode), subtitle: memoryDescription(mode))
                })
        ]
    }

    private func memoryDescription(_ mode: MemoryMode) -> String {
        switch mode {
        case .smart: L10n.Memory.smartDesc
        case .daily: L10n.Memory.dailyDesc
        case .full: L10n.Memory.fullDesc
        }
    }

    private func memoryName(_ mode: MemoryMode) -> String {
        switch mode {
        case .smart: L10n.Memory.smartChapters
        case .daily: L10n.Memory.daily
        case .full: L10n.Memory.full
        }
    }
}

extension RuntimeKind {
    /// The runtimes a new agent can pick. The API-key runtime is not in this build, so it has no card.
    static let pickable: [RuntimeKind] = [.claude, .codex, .grok]
}

extension AvatarFace {
    /// The faces the avatar editor offers, in the design's order: the three first, then the six new ones.
    static let faces: [AvatarFace] = [
        .chevronDash, .dots, .carets, .wink, .surprised, .sleeping, .glasses, .happy, .serious,
    ]
}

/// The layout of the runtime cards: two per row. Kept out of the view, which is main-actor isolated, so it can be tested.
enum RuntimeCardRows {
    /// The runtimes in pairs, in order.
    static func pairs(_ kinds: [RuntimeKind]) -> [[RuntimeKind]] {
        stride(from: 0, to: kinds.count, by: 2).map { Array(kinds[$0..<min($0 + 2, kinds.count)]) }
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

/// What a runtime card shows: text, tint and whether the limit windows are drawn. Pure, so the rules are easy to read
/// and test. The reset times of the windows are shown on the windows themselves.
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
    let tint: Color
    /// Where to read how to install the CLI. Only for a runtime that is not installed.
    let installURL: URL?
    /// The command that signs the person in, shown in monospace. Only when the runtime is not signed in.
    var command: String?

    /// The limit windows are drawn for a signed-in runtime that reports limits.
    var showsLimit: Bool { kind == .limits || kind == .exhausted }

    /// `remaining` is the share left across the runtime's windows (the most used one decides). `exhaustedUntil` is
    /// when the used-up windows reset (see `UsageCards.exhaustedReset`), or nil when that is not known.
    static func make(
        runtime: RuntimeKind, status: RuntimeStatus?, requestDone: Bool, remaining: Double?, exhaustedUntil: Date?,
        now: Date
    ) -> RuntimeCardState {
        guard let status else {
            if requestDone {
                return RuntimeCardState(
                    kind: .unknown, text: L10n.AgentSheet.statusUnknown, tint: Color.Bandito.text3, installURL: nil)
            }
            return RuntimeCardState(
                kind: .checking, text: L10n.AgentSheet.statusChecking, tint: Color.Bandito.text3, installURL: nil)
        }
        if !status.installed {
            return RuntimeCardState(
                kind: .notInstalled, text: L10n.AgentSheet.statusNotInstalled, tint: Color.Bandito.danger,
                installURL: RuntimeInstallLinks.url(for: runtime))
        }
        if status.loggedIn == false {
            return RuntimeCardState(
                kind: .needsLogin, text: L10n.AgentSheet.statusNeedsLogin, tint: BanditoPalette.peach,
                installURL: nil, command: LoginCommand.arguments(for: runtime).joined(separator: " "))
        }
        guard let remaining else {
            let text = versionLabel(status.version).map { L10n.AgentSheet.statusReadyVersion(version: $0) }
                ?? L10n.AgentSheet.statusReady
            return RuntimeCardState(kind: .ready, text: text, tint: Color.Bandito.ok, installURL: nil)
        }
        if remaining <= 0 {
            // With a known reset: "Limit used up · again in 5 d". Without one: just "Limit used up", never "again" alone.
            let text = exhaustedUntil.map {
                L10n.AgentSheet.statusExhausted(time: Countdown.text(to: $0, now: now))
            } ?? L10n.AgentSheet.statusExhaustedPlain
            return RuntimeCardState(kind: .exhausted, text: text, tint: Color.Bandito.danger, installURL: nil)
        }
        let used = Int(((1 - remaining) * 100).rounded())
        return RuntimeCardState(
            kind: .limits, text: L10n.AgentSheet.statusSignedInPlain,
            tint: UsageLevel(usedPercent: used).color, installURL: nil)
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
struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(BanditoFont.text(size: 13.5, weight: 400))
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
                    .font(BanditoFont.text(size: 12, weight: 400))
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
