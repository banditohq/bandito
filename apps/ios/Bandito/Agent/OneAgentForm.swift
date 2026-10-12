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
    @State private var permissions = Set(AgentPermission.allCases)
    @State private var root: String?
    @State private var busy = false
    @State private var installing = false
    @State private var failure: String?
    @State private var madeCount = 0

    /// The runtimes a person can run an agent on, in the Mac's order.
    static let runtimes = [RuntimeKind.claude, .codex, .grok]

    private var installed: Bool {
        server.runtimes.contains { $0.kind == runtime && $0.installed }
    }

    private var models: [RuntimeModel] {
        server.runtimeModels[runtime.rawValue]?.models ?? []
    }

    /// The model the form sends: the person's pick, else the runtime's preferred one, else the runtime's default ("").
    private var model: String {
        pickedModel ?? AgentRules.preferredModel(runtime: runtime, models: models) ?? ""
    }

    private var folderBase: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentRules.folderName(for: trimmed.isEmpty ? L10n.AgentSheet.autoName(number: "1") : trimmed)
    }

    private var folderPreview: String? {
        root.map { AgentRules.folderPath(root: $0, name: folderBase) }
    }

    private var canCreate: Bool {
        AgentRules.canCreateOne(
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
                    ForEach(Self.runtimes, id: \.self) { kind in
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
                            Task { await install() }
                        } label: {
                            Text(installing ? L10n.Browser.installing : L10n.Setup.install)
                                .foregroundStyle(Color.Bandito.signal)
                        }
                        .disabled(installing)
                        .accessibilityIdentifier("oneAgent.install")
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

            Section {
                ForEach(AgentRules.approvalOrder, id: \.self) { mode in
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
                    ForEach(AgentPermission.allCases) { permission in
                        PermissionChip(permission: permission, on: permissions.contains(permission)) {
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

            if let failure {
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
                        Text(L10n.AgentSheet.create)
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
        .sensoryFeedback(.success, trigger: madeCount)
        .task {
            if !installed, let first = Self.runtimes.first(where: { kind in
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

    /// The model picker: a pick is kept, and "Default" is a pick too (an empty string).
    private var modelBinding: Binding<String> {
        Binding(
            get: { model },
            set: { value in pickedModel = value })
    }

    private func create() async {
        guard installed, let root else { return }
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let folder = try await AgentFolders.makeFree(root: root, base: folderBase, server: server)
            let request = AgentRules.newAgent(
                name: name, role: role, runtime: runtime, model: model.isEmpty ? nil : model, folder: folder,
                approval: approval, effort: effort, permissions: permissions)
            _ = try await server.createAgent(request)
            madeCount += 1
            onMade()
        } catch {
            failure = AgentRules.errorText(error)
        }
    }

    /// Installs the runtime (`setup.install`, the Mac's way), then reads the server's runtimes again.
    private func install() async {
        installing = true
        defer { installing = false }
        failure = nil
        do {
            let job = try await server.setupInstall(components: [runtime.rawValue])
            var offset: UInt64 = 0
            while true {
                let state = try await server.setupJob(job, from: offset)
                offset = state.offset
                if state.state == .failed {
                    failure = L10n.Browser.installFailed
                    break
                }
                if state.state != .running {
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            try await server.refreshRuntimes()
        } catch {
            failure = AgentRules.errorText(error)
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

/// One "may do" chip: a switch. An on chip has a solid outline and a check, an off chip a dashed one and a plus.
struct PermissionChip: View {
    let permission: AgentPermission
    let on: Bool
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
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("permission.\(permission.rawValue)")
    }
}
