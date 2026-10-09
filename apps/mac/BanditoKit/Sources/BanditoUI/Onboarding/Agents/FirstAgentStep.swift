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
    private(set) var creating = false
    private(set) var errorText: String?

    init(server: ServerModel, subscriptions: SubscriptionsModel) {
        self.server = server
        self.subscriptions = subscriptions
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
            && !name.trimmingCharacters(in: .whitespaces).isEmpty && !folder.isEmpty && !creating
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
        folder = AgentFolder.defaultPath(home: home, name: trimmed.isEmpty ? "agent" : trimmed)
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
            let agent = try await server.createAgent(NewAgent(
                name: name.trimmingCharacters(in: .whitespaces),
                role: template == .scratch ? "" : template.title,
                runtime: runtime,
                cwd: folder,
                approvalMode: .risky,
                systemPrompt: template.instructions.isEmpty ? nil : template.instructions,
                effort: template.effort))
            return agent
        } catch {
            errorText = SignInMessages.text(for: error)
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
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Onboarding.Agent.title)
                .font(BanditoFont.font(size: 30, weight: 600))
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
                Text(errorText)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .task { await model.loadHome() }
        .sheet(isPresented: $pickingFolder) {
            FolderPicker(
                server: model.server,
                selection: Binding(get: { model.folder }, set: { model.setFolder($0) })
            ) { pickingFolder = false }
        }
    }

    private var noSubscription: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Onboarding.Agent.needSubscription)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            Button(L10n.Onboarding.Agent.toSubscriptions, action: onNeedSubscription)
                .buttonStyle(SignalButtonStyle())
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
            HStack(spacing: 8) {
                Text(L10n.Onboarding.Agent.workplace)
                    .font(BanditoFont.font(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                Text(L10n.Onboarding.Agent.workplaceShared)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Button(L10n.Onboarding.Agent.hire(name: model.name.trimmingCharacters(in: .whitespaces))) {
                Task { await hire() }
            }
            .buttonStyle(SignalButtonStyle())
            .disabled(!model.canCreate)
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
                        .buttonStyle(QuietButtonStyle(size: .regular))
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
                    .buttonStyle(QuietButtonStyle(size: .regular))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
        }
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
                phase = .firstAgent
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
