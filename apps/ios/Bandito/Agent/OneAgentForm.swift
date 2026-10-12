import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "One agent": a name, a role, the runtime and its model (Haiku on Claude Code by default, as on the Mac), the effort,
/// the approvals, what it may do, and its own folder on the server. A runtime the server lacks shows how to install it.
struct OneAgentForm: View {
    let server: ServerModel
    let onMade: () -> Void

    @State private var name = ""
    @State private var role = ""
    @State private var runtime = RuntimeKind.claude
    /// The model the person picked; until one is picked, the preferred model of the runtime is used.
    @State private var pickedModel: String?
    @State private var effort: Effort?
    @State private var approval = ApprovalMode.risky
    @State private var permissions = Set(AgentCapability.allCases)
    @State private var root: String?
    /// The creation, once a first attempt started: it keeps the folder for the attempts after it.
    @State private var creation: OneAgentCreation?
    @State private var installRound = 0
    @State private var installing = false
    @State private var installFailure: String?

    /// How long the install is watched: this many one-second polls. Then the form says so and offers a retry.
    static let installPolls = 900

    private var installed: Bool {
        server.runtimes.contains { $0.kind == runtime && $0.installed }
    }

    private var models: [RuntimeModel] {
        server.runtimeModels[runtime.rawValue]?.models ?? []
    }

    /// The model the form sends: the person's pick, else the runtime's preferred one, else the runtime's default ("").
    private var model: String {
        pickedModel ?? NewAgentModelRules.preferredModel(runtime: runtime, models: models) ?? ""
    }

    private var folderBase: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewAgentFolderRules.folderName(for: trimmed.isEmpty ? L10n.AgentSheet.autoName(number: "1") : trimmed)
    }

    /// The folder the agent gets: the one already made by a failed attempt, else the one it would get now.
    private var folderPreview: String? {
        if let folder = creation?.folder { return folder }
        return root.map { NewAgentFolderRules.folderPath(root: $0, name: folderBase) }
    }

    private var unavailable: [AgentCapability: String] {
        AgentCapability.unavailable(infoKnown: server.info != nil, supports: { server.supports($0) })
    }

    private var busy: Bool {
        creation?.busy ?? false
    }

    private var canCreate: Bool {
        AgentForms.canCreateOne(
            name: name, runtime: installed ? runtime : nil, folder: folderPreview ?? "", busy: busy || installing)
    }

    var body: some View {
        List {
            Section {
                TextField(L10n.AgentSheet.name, text: $name)
                    .submitLabel(.next)
                    .accessibilityIdentifier("oneAgent.name")
                TextField(L10n.AgentSheet.rolePlaceholder, text: $role)
                    .submitLabel(.done)
                    .accessibilityIdentifier("oneAgent.role")
            }
            .listRowBackground(Color.Bandito.surface1)

            Section {
                Picker(L10n.AgentSheet.runtime, selection: $runtime) {
                    ForEach(AgentForms.runtimes, id: \.self) { kind in
                        Text(runtimeName(kind)).tag(kind)
                    }
                }
                .accessibilityIdentifier("oneAgent.runtime")
                if !installed {
                    VStack(alignment: .leading, spacing: BanditoSpace.s2) {
                        Text(L10n.AgentSheet.runtimeMissing(runtime: runtimeName(runtime), server: server.config.name))
                            .font(BanditoFont.text(size: 14))
                            .foregroundStyle(Color.Bandito.text2)
                        Button {
                            installRound += 1
                        } label: {
                            Text(installButtonTitle)
                                .foregroundStyle(Color.Bandito.signal)
                        }
                        .disabled(installing)
                        .accessibilityIdentifier("oneAgent.install")
                        if let installFailure {
                            Text(installFailure)
                                .font(BanditoFont.text(size: 13))
                                .foregroundStyle(Color.Bandito.danger)
                        }
                    }
                    .listRowBackground(Color.Bandito.surface1)
                }
            }
            .listRowBackground(Color.Bandito.surface1)

            Section {
                Picker(L10n.AgentSheet.model, selection: modelBinding) {
                    Text(L10n.ModelPicker.defaultPlain).tag("")
                    ForEach(models) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                Picker(L10n.Effort.title, selection: $effort) {
                    Text(L10n.ModelPicker.defaultPlain).tag(Effort?.none)
                    ForEach(runtime.supportedEfforts, id: \.self) { level in
                        Text(effortName(level)).tag(Optional(level))
                    }
                }
            }
            .listRowBackground(Color.Bandito.surface1)
            // A model or a runtime that takes fewer levels moves the effort to the nearest one it takes (the Mac's rule).
            .onChange(of: runtime) { _, next in
                let moved = AgentForms.afterRuntimeChange(
                    to: next, pickedModel: pickedModel, effort: effort, lists: server.runtimeModels)
                pickedModel = moved.pickedModel
                effort = moved.effort
            }

            Section {
                ForEach(AgentForms.approvalOrder, id: \.self) { mode in
                    Button {
                        approval = mode
                    } label: {
                        HStack {
                            Text(approvalTitle(mode))
                                .foregroundStyle(Color.Bandito.text)
                            Spacer()
                            if approval == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.Bandito.signal)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.Bandito.surface1)
                    .accessibilityAddTraits(approval == mode ? .isSelected : [])
                }
            } header: {
                Text(L10n.AgentSheet.askAbout)
            } footer: {
                Text(approvalHint(approval))
            }

            Section {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: BanditoSpace.s2, alignment: .leading)],
                    alignment: .leading, spacing: BanditoSpace.s2
                ) {
                    ForEach(AgentCapability.allCases) { permission in
                        PermissionChip(
                            permission: permission, on: permissions.contains(permission),
                            reason: unavailable[permission]
                        ) {
                            if permissions.contains(permission) {
                                permissions.remove(permission)
                            } else {
                                permissions.insert(permission)
                            }
                        }
                    }
                }
                .padding(.vertical, BanditoSpace.s1)
                .listRowBackground(Color.Bandito.surface1)
            } header: {
                Text(L10n.Capability.title)
            }

            Section {
                if let folderPreview {
                    Text(folderPreview)
                        .font(BanditoFont.mono(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .listRowBackground(Color.Bandito.surface1)
                }
            } header: {
                Text(L10n.AgentSheet.folder)
            } footer: {
                Text(L10n.AgentSheet.folderNewHint)
            }

            if let failure = creation?.failure {
                Section {
                    Text(failure)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.danger)
                        .listRowBackground(Color.Bandito.surface1)
                        .accessibilityIdentifier("oneAgent.error")
                }
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Spacer()
                        Text(creation?.failure == nil ? L10n.AgentSheet.create : L10n.Banner.retry)
                        Spacer()
                    }
                }
                .disabled(!canCreate)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("oneAgent.create")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: creation?.madeCount ?? 0)
        // The install is a task of the form: leaving the sheet cancels the watching of it.
        .task(id: installRound) {
            guard installRound > 0 else { return }
            await install()
        }
        .task {
            if !installed, let first = AgentForms.runtimes.first(where: { kind in
                server.runtimes.contains { $0.kind == kind && $0.installed }
            }) {
                runtime = first
            }
            root = await AgentFolders.root(server: server)
            if server.runtimes.isEmpty {
                try? await server.refreshRuntimes()
            }
            if server.runtimeModels.isEmpty {
                try? await server.refreshRuntimeModels()
            }
        }
    }

    private var installButtonTitle: String {
        if installing { return L10n.Browser.installing }
        return installFailure == nil ? L10n.Setup.install : L10n.Banner.retry
    }

    /// The model picker: a pick is kept, and "Default" is a pick too (an empty string).
    private var modelBinding: Binding<String> {
        Binding(
            get: { model },
            set: { value in pickedModel = value })
    }

    private func create() async {
        guard installed, let root else { return }
        let attempt: OneAgentCreation
        if let creation {
            attempt = creation
        } else {
            attempt = OneAgentCreation(server: server, root: root, base: folderBase)
            creation = attempt
        }
        let sent = permissions.subtracting(unavailable.keys)
        let made = await attempt.create { folder in
            AgentForms.newAgent(
                name: name, role: role, runtime: runtime, model: model.isEmpty ? nil : model, folder: folder,
                approval: approval, effort: effort, permissions: sent)
        }
        if made { onMade() }
    }

    /// Installs the runtime (`setup.install`, the Mac's way) and watches it for `installPolls` seconds at most; then the
    /// server's runtimes are read again. A failure, or no end within the limit, is said and can be retried.
    private func install() async {
        installing = true
        defer { installing = false }
        installFailure = nil
        do {
            let job = try await server.setupInstall(components: [runtime.rawValue])
            var offset: UInt64 = 0
            for _ in 0..<Self.installPolls {
                try Task.checkCancellation()
                let state = try await readJob(job, from: offset)
                offset = state.offset
                if state.state == .failed || state.state == .needsPassword {
                    installFailure = L10n.Browser.installFailed
                    return
                }
                if state.state != .running {
                    try await server.refreshRuntimes()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            installFailure = L10n.Ios.NewAgent.installTimedOut
        } catch is CancellationError {
            return
        } catch {
            installFailure = AgentForms.errorText(error)
        }
    }

    /// Reads the job from `offset`. A failed read is repeated once after a short wait, as the Mac does.
    private func readJob(_ id: String, from offset: UInt64) async throws -> SetupJob {
        do {
            return try await server.setupJob(id, from: offset)
        } catch {
            try await Task.sleep(for: .seconds(1))
            return try await server.setupJob(id, from: offset)
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
}

/// One "may do" chip: a switch. An on chip has a solid outline and a check, an off chip a dashed one and a plus. A chip
/// the server cannot give is disabled and says why (the Mac's `CapabilityChips`).
struct PermissionChip: View {
    let permission: AgentCapability
    let on: Bool
    /// The reason the server cannot give this chip; nil when it can.
    var reason: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark" : "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(permission.title)
                    .lineLimit(1)
            }
            .font(BanditoFont.text(size: 13, weight: 500))
            .foregroundStyle(on ? Color.Bandito.text : Color.Bandito.text3)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .overlay {
                Capsule().stroke(on ? Color.Bandito.line : Color.Bandito.text.opacity(0.22), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(reason ?? "")
        .accessibilityIdentifier("permission.\(permission.rawValue)")
    }
}
