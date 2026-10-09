import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Creates the first agent: a template, a name, a runtime that is signed in, a folder, the workplace.
@MainActor
@Observable
final class FirstAgentModel {
    let server: ServerModel
    let subscriptions: SubscriptionsModel

    private(set) var template: AgentTemplate?
    private(set) var name = ""
    private(set) var runtime: RuntimeKind?
    private(set) var home: String?
    private(set) var folder = ""
    private(set) var folderCustomized = false
    @ObservationIgnored private var folderGeneration = 0
    private(set) var creating = false
    private(set) var errorText: UserFacingMessage?
    /// The server's workplaces: the containers that exist and whether a separate one can be made.
    let workplaces: WorkspacesModel
    private(set) var workplace: WorkplaceChoice = .shared
    private(set) var newWorkplace = NewWorkplaceDraft()

    init(server: ServerModel, subscriptions: SubscriptionsModel) {
        self.server = server
        self.subscriptions = subscriptions
        self.workplaces = WorkspacesModel(server: server)
    }

    /// Only runtimes that are signed in can run an agent.
    var signedIn: [RuntimeKind] {
        subscriptions.signedIn
    }

    var existingNames: [String] {
        server.agents.map(\.name)
    }

    /// The name's problem, or nil. An empty name is not a problem yet: the person has not typed it.
    var nameProblem: AgentNameRule.Problem? {
        AgentNameRule.problem(for: name, existing: existingNames)
    }

    var canCreate: Bool {
        template != nil && runtime != nil && nameProblem == nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty && !folder.isEmpty && !creating && workplaceReady
    }

    /// The chosen workplace can be used: the shared server, a container that still exists, or a new one that can be made.
    var workplaceReady: Bool {
        switch workplace {
        case .shared: true
        case .existing(let id): workplaces.containers.contains { $0.id == id }
        case .new: workplaces.canCreateSeparate && newWorkplace.canCreate
        }
    }

    /// Shared server, or a separate workplace. Switching to separate picks the first container, or a new one.
    func setSeparate(_ separate: Bool) {
        guard !separate else {
            guard workplaces.canCreateSeparate, workplace == .shared else { return }
            if let first = workplaces.containers.first {
                workplace = .existing(first.id)
            } else {
                workplace = .new
            }
            return
        }
        workplace = .shared
    }

    func chooseExisting(_ id: String) {
        workplace = .existing(id)
    }

    func chooseNewWorkplace() {
        workplace = .new
    }

    func setNewWorkplaceName(_ text: String) {
        newWorkplace.name = text
    }

    func loadHome() async {
        do {
            home = try await server.list("~").path
            refreshFolder()
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    func choose(_ template: AgentTemplate) {
        self.template = template
        runtime = AgentRuntimeChoice.pick(preferred: template.runtime, signedIn: signedIn)
    }

    func chooseRuntime(_ kind: RuntimeKind) {
        guard signedIn.contains(kind) else { return }
        runtime = kind
    }

    func setName(_ text: String) {
        name = text
        refreshFolder()
    }

    /// The folder the person picked by hand is kept as it is when the name changes.
    func setFolder(_ path: String) {
        folder = path
        folderCustomized = true
    }

    private func refreshFolder() {
        guard !folderCustomized, let home else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = AgentFolder.defaultPath(home: home, name: trimmed.isEmpty ? "agent" : trimmed)
        folder = base
        // The name is free only when no agent and no folder in projects has it. Answers for an older name are dropped.
        folderGeneration += 1
        let generation = folderGeneration
        Task { [weak self] in
            await self?.resolveFolder(base: base, home: home, generation: generation)
        }
    }

    private func resolveFolder(base: String, home: String, generation: Int) async {
        var taken = Set(server.agents.map(\.cwd))
        let projects = home + "/projects"
        if let listing = try? await server.list(projects) {
            taken.formUnion(listing.entries.map { projects + "/" + $0.name })
        }
        guard generation == folderGeneration, !folderCustomized else { return }
        folder = AgentFolder.unique(base, taken: taken)
    }

    /// Creates the agent. The folder (and `projects` above it) is made when missing, unless the person chose one.
    func create() async -> Agent? {
        guard canCreate, let template, let runtime else { return nil }
        creating = true
        defer { creating = false }
        do {
            if !folderCustomized {
                try await ensureDefaultFolder()
            }
            let workspaceID = try await WorkplaceCreation.prepare(workplace, new: newWorkplace, on: server)
            let agent = try await server.createAgent(NewAgent(
                name: name.trimmingCharacters(in: .whitespaces),
                role: template == .scratch ? "" : template.title,
                runtime: runtime,
                cwd: folder,
                approvalMode: .risky,
                systemPrompt: template.instructions.isEmpty ? nil : template.instructions,
                effort: template.effort,
                workspaceId: workspaceID))
            return agent
        } catch {
            errorText = WorkspaceText.failure(error).map { UserFacingMessage(text: $0) } ?? SignInMessages.text(for: error)
            return nil
        }
    }

    private func ensureDefaultFolder() async throws {
        guard let home else { return }
        try await createIfMissing(home + "/projects")
        try await createIfMissing(folder)
    }

    private func createIfMissing(_ path: String) async throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        let listing = try await server.list(parent)
        if listing.entries.contains(where: { $0.name == leaf }) { return }
        _ = try await server.mkdir(path)
    }
}

/// Step 4 of 5, part two: the template cards, the form, and the hire button.
struct FirstAgentStep: View {
    var model: FirstAgentModel
    /// No runtime is signed in: back to the subscriptions.
    var onNeedSubscription: () -> Void
    /// The agent exists and the composer has its first message: the flow ends with the tour.
    var onCreated: () -> Void

    @Environment(Router.self) private var router
    @State private var pickingFolder = false

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.Onboarding.Agent.title)
                    .font(BanditoFont.font(size: 38, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Onboarding.Agent.subtitle)
                    .font(BanditoFont.font(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                if model.signedIn.isEmpty {
                    noSubscription
                } else {
                    templates
                    if model.template != nil {
                        form
                    }
                }
                if let errorText = model.errorText {
                    UserFacingErrorView(message: errorText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The preview of the agent to be hired. Its place is kept before a template is picked, so nothing shifts.
            if !model.signedIn.isEmpty {
                preview
                    .frame(width: 320)
                    .opacity(model.template == nil ? 0 : 1)
                    .accessibilityHidden(model.template == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onboardingNext(hireAction)
        .task {
            await model.loadHome()
            await model.workplaces.load()
        }
        .sheet(isPresented: $pickingFolder) {
            FolderPicker(
                server: model.server,
                selection: Binding(get: { model.folder }, set: { model.setFolder($0) })
            ) { pickingFolder = false }
        }
    }

    /// The agent as it will be hired: avatar, name, the settings in rows, the template's description.
    @ViewBuilder
    private var preview: some View {
        if let template = model.template {
            let shownName = model.name.trimmingCharacters(in: .whitespaces).isEmpty
                ? template.title : model.name.trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.Onboarding.Agent.yourFirst)
                    .font(BanditoFont.font(size: 11, weight: 600))
                    .tracking(0.8)
                    .foregroundStyle(Color.Bandito.text3)
                HStack(spacing: 14) {
                    RaccoonAvatar(name: template.title, color: color(template), size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shownName)
                            .font(BanditoFont.font(size: 20, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(template.title)
                            .font(BanditoFont.font(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
                VStack(spacing: 0) {
                    previewRow(L10n.Onboarding.Agent.runtimeLabel, model.runtime.map(runtimeTitle) ?? "—")
                    previewRow(L10n.Onboarding.Agent.folderLabel, model.folder)
                    previewRow(L10n.Onboarding.Agent.workplace, model.workplace.mode == .separate
                        ? L10n.Workspace.Choice.separate : L10n.Workspace.Choice.shared)
                }
                .background(Color.Bandito.text.opacity(0.02), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.08)))
                Text(template.description)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.Onboarding.Agent.firstMessage(name: shownName))
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.Bandito.text.opacity(0.1)))
        }
    }

    private func previewRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Spacer(minLength: 8)
            Text(value)
                .font(BanditoFont.font(size: 13, weight: 500, mono: key == L10n.Onboarding.Agent.folderLabel))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    /// The hire button sits in the flow's bottom bar, once a template is chosen and a runtime is signed in.
    private var hireAction: OnboardingNextAction? {
        guard !model.signedIn.isEmpty, model.template != nil else { return nil }
        return OnboardingNextAction(
            title: L10n.Onboarding.Agent.hire(name: model.name.trimmingCharacters(in: .whitespaces)),
            isEnabled: model.canCreate
        ) {
            Task { await hire() }
        }
    }

    private var noSubscription: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Onboarding.Agent.needSubscription)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            Button(L10n.Onboarding.Agent.toSubscriptions, action: onNeedSubscription)
                .banditoButton(.signal())
        }
        .padding(16)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 16))
    }

    private var templates: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(AgentTemplate.allCases, id: \.self) { template in
                let selected = model.template == template
                Button {
                    model.choose(template)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        RaccoonAvatar(name: template.title, color: color(template), size: 34)
                        Text(template.title)
                            .font(BanditoFont.font(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        Text(template.description)
                            .font(BanditoFont.font(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selected ? Color.Bandito.signal : Color.Bandito.text.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .banditoAnimation(BanditoMotion.ease, value: selected)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Onboarding.Agent.nameLabel)
                    .font(BanditoFont.font(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                TextField(model.template?.title ?? "", text: Binding(get: { model.name }, set: { model.setName($0) }))
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 14.5, weight: 400))
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.text.opacity(0.12)))
                if !model.name.isEmpty, let problem = model.nameProblem {
                    Text(Self.problemText(problem))
                        .font(BanditoFont.font(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                }
            }
            runtimeRow
            folderRow
            workplaceRow
        }
    }

    private var runtimeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Onboarding.Agent.runtimeLabel)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            HStack(spacing: 6) {
                ForEach(model.signedIn, id: \.self) { kind in
                    Button(runtimeTitle(kind)) { model.chooseRuntime(kind) }
                        .banditoButton(.quiet(size: .regular))
                        .overlay(
                            RoundedRectangle(cornerRadius: 999)
                                .stroke(model.runtime == kind ? Color.Bandito.signal : .clear, lineWidth: 1.5))
                }
            }
        }
    }

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Onboarding.Agent.folderLabel)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            HStack(spacing: 10) {
                Text(model.folder)
                    .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(L10n.Onboarding.Agent.changeFolder) { pickingFolder = true }
                    .banditoButton(.quiet(size: .regular))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Where the agent runs: the shared server, or a separate workplace (an existing container or a new one).
    /// Separate needs Docker on the server; without the feature the row only says where the agent runs.
    private var workplaceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Onboarding.Agent.workplace)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            if model.workplaces.canCreateSeparate {
                HStack(spacing: 6) {
                    placeChip(L10n.Workspace.Choice.shared, selected: model.workplace.mode == .shared) {
                        model.setSeparate(false)
                    }
                    placeChip(L10n.Workspace.Choice.separate, selected: model.workplace.mode == .separate) {
                        model.setSeparate(true)
                    }
                }
                if model.workplace.mode == .separate {
                    HStack(spacing: 6) {
                        ForEach(model.workplaces.containers) { container in
                            placeChip(container.name, selected: model.workplace == .existing(container.id)) {
                                model.chooseExisting(container.id)
                            }
                        }
                        placeChip(L10n.Workspace.Choice.newOne, selected: model.workplace == .new) {
                            model.chooseNewWorkplace()
                        }
                    }
                    if model.workplace == .new {
                        TextField(
                            L10n.Workspace.Create.name,
                            text: Binding(get: { model.newWorkplace.name }, set: { model.setNewWorkplaceName($0) })
                        )
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 14, weight: 400))
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.text.opacity(0.12)))
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
            } else {
                Text(L10n.Onboarding.Agent.workplaceShared)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                if model.workplaces.supported {
                    Text(L10n.Workspace.Choice.dockerNeeded)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func placeChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .banditoButton(.quiet(size: .regular))
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(selected ? Color.Bandito.signal : .clear, lineWidth: 1.5))
    }

    private func hire() async {
        guard let agent = await model.create() else { return }
        router.selectedAgentID = agent.id
        router.select(mode: .team)
        router.pendingComposerText = L10n.Onboarding.Agent.composerText
        onCreated()
    }

    private func runtimeTitle(_ kind: RuntimeKind) -> String {
        model.subscriptions.title(kind)
    }

    private func color(_ template: AgentTemplate) -> AvatarColor {
        switch template {
        case .builder: .peach
        case .reviewer: .sky
        case .oncall: .rose
        case .assistant: .lilac
        case .researcher: .sage
        case .scratch: .cream
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

/// Steps 4 of 5 as one screen: first the subscriptions, then the first agent. Polls the runtimes while open.
struct AgentStep: View {
    /// The agent exists: the flow ends and the tour starts.
    var onCreated: () -> Void

    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .subscriptions
    @State private var subscriptions: SubscriptionsModel?
    @State private var first: FirstAgentModel?

    private enum Phase {
        case subscriptions
        case firstAgent
    }

    var body: some View {
        Group {
            if let subscriptions, let first {
                content(subscriptions, first)
            } else {
                Text(L10n.Onboarding.Agent.noServer)
                    .font(BanditoFont.font(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
        }
        .onAppear(perform: build)
        .task {
            while !Task.isCancelled {
                await subscriptions?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear {
            Task { await subscriptions?.endLogin() }
        }
    }

    @ViewBuilder
    private func content(_ subscriptions: SubscriptionsModel, _ first: FirstAgentModel) -> some View {
        switch phase {
        case .subscriptions:
            SubscriptionsStep(model: subscriptions) {
                // The login terminal belongs to the subscriptions step: it closes before the form opens.
                Task {
                    await subscriptions.endLogin()
                    phase = .firstAgent
                }
            }
        case .firstAgent:
            FirstAgentStep(model: first) {
                phase = .subscriptions
            } onCreated: {
                onCreated()
            }
        }
    }

    private func build() {
        guard subscriptions == nil, let server = app.currentServer else { return }
        let model = SubscriptionsModel(server: server)
        subscriptions = model
        first = FirstAgentModel(server: server, subscriptions: model)
    }
}
