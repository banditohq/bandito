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
    @State private var error: String?

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
                HStack(alignment: .top, spacing: 26) {
                    leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                    rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            footer
        }
        .frame(width: 1080, height: 820)
        .background(Color.Bandito.surface2)
        .onAppear {
            if let cwd = router.pendingAgentCwd {
                draft.cwd = cwd
                router.pendingAgentCwd = nil
            }
        }
        .task {
            guard let server else { return }
            // Limits and runtime status are shown when they arrive; a failure leaves the cards in "checking".
            do { try await server.refreshRuntimes() } catch {}
            _ = try? await server.usageLimits()
        }
    }

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
                        .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .accessibilityLabel(faceName(face))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                labeled(L10n.AgentSheet.name) {
                    TextField("", text: $draft.name)
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

            HStack(alignment: .top, spacing: 12) {
                labeled(L10n.AgentSheet.model) {
                    modelField
                }
                .frame(maxWidth: .infinity)
                labeled(L10n.Effort.title) {
                    SegmentedPicker(
                        selection: $draft.effort,
                        options: draft.runtime.supportedEfforts.map { ($0, effortName($0)) })
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            }
            Text(effortHint(draft.effort))
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: -6)

            labeled(L10n.AgentSheet.fallbackLabel) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.ok)
                    Text(L10n.AgentSheet.fallbackNone)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                    Spacer(minLength: 0)
                    Text(L10n.Common.comingSoon)
                        .font(BanditoFont.font(size: 10.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.Bandito.text.opacity(0.07), in: Capsule())
                }
                .modifier(FieldBox())
                .opacity(0.7)
                .help(L10n.Common.comingSoon)
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
                runtimeSoonCard
            }
        }
    }

    private func runtimeCard(_ kind: RuntimeKind, now: Date) -> some View {
        let selected = draft.runtime == kind
        let card = usageCards.first { $0.runtime == kind.rawValue }
        // Only this runtime's card counts: `percentLeft` falls back to all cards when given no runtime.
        let remaining = card.flatMap { UsageCards.percentLeft([$0], runtime: nil) }
        let state = RuntimeCardState.make(
            installed: runtimeStatus(kind)?.installed, loggedIn: runtimeStatus(kind)?.loggedIn,
            remaining: remaining, resetsAt: card?.windows.compactMap(\.resetsAt).min(),
            hasUsage: card != nil, now: now)
        return Button {
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
                HStack(spacing: 5) {
                    Circle().fill(state.tint).frame(width: 6, height: 6)
                    Text(state.text)
                        .font(BanditoFont.font(size: 11.5, weight: 400))
                        .foregroundStyle(state.tint)
                        .lineLimit(1)
                }
                UsageBar(fraction: remaining ?? 0, tint: state.barTint, height: 4)
                    .opacity(remaining == nil ? 0.35 : 1)
                Text(state.hint)
                    .font(BanditoFont.font(size: 11, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
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
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The API-key card: the runtime is not in this build, so it is only shown.
    private var runtimeSoonCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(L10n.AgentSheet.apiKey)
                    .font(BanditoFont.font(size: 13.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer(minLength: 0)
                Text(L10n.Common.comingSoon)
                    .font(BanditoFont.font(size: 10.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.Bandito.text.opacity(0.07), in: Capsule())
            }
            Text(L10n.AgentSheet.apiKeyHint)
                .font(BanditoFont.font(size: 11, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Bandito.text.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .opacity(0.7)
        .accessibilityElement(children: .combine)
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
                .buttonStyle(.plain)
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
                        .buttonStyle(QuietButtonStyle(size: .regular))
                        .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                            if let server {
                                FolderPicker(server: server, selection: $draft.cwd) { pickerOpen = false }
                            }
                        }
                }
                .modifier(FieldBox())
            }

            VStack(alignment: .leading, spacing: 7) {
                labeledHeader(L10n.AgentSheet.workplace, hint: L10n.AgentSheet.workplaceHint)
                HStack(spacing: 8) {
                    workplaceCard(
                        name: L10n.AgentSheet.workplaceShared, text: L10n.AgentSheet.workplaceSharedText,
                        selected: true, enabled: true)
                    workplaceCard(
                        name: L10n.AgentSheet.workplaceSeparate, text: L10n.AgentSheet.workplaceSeparateText,
                        selected: false, enabled: false)
                    workplaceCard(
                        name: L10n.AgentSheet.workplaceContainer, text: L10n.AgentSheet.workplaceContainerText,
                        selected: false, enabled: false)
                }
                Text(L10n.AgentSheet.workplaceSoonHint)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }

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
                        .buttonStyle(.plain)
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

    private func workplaceCard(name: String, text: String, selected: Bool, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(BanditoFont.font(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(text)
                .font(BanditoFont.font(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.Bandito.signal.opacity(0.08) : Color.Bandito.text.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(selected ? Color.Bandito.signal.opacity(0.5) : Color.Bandito.text.opacity(0.09)))
        .opacity(enabled ? 1 : 0.5)
        .help(enabled ? "" : L10n.Common.comingSoon)
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
                Text(error)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Text(L10n.AgentSheet.changeLater)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                Spacer(minLength: 0)
                Button(L10n.AgentSheet.cancel) { router.sheet = nil }
                    .buttonStyle(QuietButtonStyle(size: .regular))
                Button(L10n.AgentSheet.create(name: trimmedName)) { create() }
                    .buttonStyle(SignalButtonStyle(size: .regular))
                    .disabled(!draft.canCreate || creating || server == nil)
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
        let request = draft.makeNewAgent()
        Task {
            do {
                let agent = try await server.createAgent(request)
                var recent = RecentFolders.load(serverID: server.id.uuidString)
                recent.remember(agent.cwd)
                recent.save(serverID: server.id.uuidString)
                router.selectedAgentID = agent.id
                router.select(mode: .team)
                router.sheet = nil
            } catch {
                self.error = error.localizedDescription
                creating = false
            }
        }
    }

    // MARK: Helpers

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// The runtimes a new agent can pick today. The API-key runtime has its own card, marked soon.
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

/// Text and tint of a runtime card. Pure, so the rules are easy to read.
struct RuntimeCardState: Equatable {
    let text: String
    let hint: String
    let tint: Color
    let barTint: Color

    static func make(
        installed: Bool?, loggedIn: Bool?, remaining: Double?, resetsAt: Date?, hasUsage: Bool, now: Date
    ) -> RuntimeCardState {
        if installed == false {
            return RuntimeCardState(
                text: L10n.AgentSheet.statusNotInstalled, hint: "", tint: Color.Bandito.danger,
                barTint: Color.Bandito.danger)
        }
        if loggedIn == false {
            return RuntimeCardState(
                text: L10n.AgentSheet.statusNotSignedIn, hint: "", tint: Color.Bandito.danger,
                barTint: Color.Bandito.danger)
        }
        guard let remaining else {
            return RuntimeCardState(
                text: hasUsage ? L10n.AgentSheet.statusSignedInPlain : L10n.AgentSheet.statusChecking, hint: "",
                tint: Color.Bandito.ok, barTint: Color.Bandito.ok)
        }
        let percent = Int((remaining * 100).rounded())
        let reset = resetsAt.map { Countdown.text(to: $0, now: now) } ?? ""
        if remaining <= 0 {
            let again = resetsAt.map { Countdown.text(to: $0, now: now, exhausted: true) } ?? ""
            return RuntimeCardState(
                text: L10n.AgentSheet.statusExhausted(time: again), hint: "", tint: Color.Bandito.danger,
                barTint: Color.Bandito.danger)
        }
        let tint = remaining < 0.25 ? BanditoPalette.peach : Color.Bandito.ok
        return RuntimeCardState(
            text: L10n.AgentSheet.statusSignedIn(percent: "\(percent)"),
            hint: reset.isEmpty ? "" : L10n.AgentSheet.resetsIn(time: reset), tint: tint,
            barTint: remaining < 0.25 ? BanditoPalette.peach : Color.Bandito.ok)
    }
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

/// Wrapping row of informative tags ("What it may do").
private struct FlowTags: View {
    struct Tag: Identifiable {
        let text: String
        let on: Bool
        var id: String { text }
    }

    let tags: [Tag]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags) { tag in
                Text(tag.text)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(tag.on ? Color.Bandito.text : Color.Bandito.text3)
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
