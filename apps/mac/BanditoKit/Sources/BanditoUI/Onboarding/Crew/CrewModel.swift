import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the "Hire your first crew" step shows and does: the ready teams (or one agent), the runtime, the shared
/// folder, the schedules, and the one tap that makes it. Making is `TeamCreation` / `OneAgentCreation`, which survive
/// a failed attempt; this model keeps them per choice, so going back and forth never makes a second set.
@MainActor
@Observable
final class CrewModel {
    enum Choice: Hashable, Sendable {
        case team(String)
        case single
    }

    enum Load: Equatable {
        case loading
        case ready
        case failed(UserFacingMessage)
    }

    let server: ServerModel
    let subscriptions: SubscriptionsModel
    @ObservationIgnored let bots = BotsMarketModel()
    /// The catalog handed in by a picture or a test that has no server to ask.
    @ObservationIgnored private let preview: ReadyTeamPreview?

    private(set) var choice: Choice?
    private(set) var runtime: RuntimeKind?
    private(set) var home: String?
    private(set) var folder = ""
    private(set) var folderCustomized = false
    /// The default folder is still being checked against the folders that exist: Create waits for it.
    private(set) var resolvingFolder = false
    /// The keys of the schedules switched on. Empty at first: nothing runs before the person confirms it.
    private(set) var enabled: Set<String> = []
    /// Where one agent runs: the shared server, or a separate container (Docker on the server).
    let workplaces: WorkspacesModel
    private(set) var workplace: WorkplaceChoice = .shared
    private(set) var newWorkplace = NewWorkplaceDraft()
    private(set) var template: AgentTemplate = .builder
    private(set) var name = ""
    @ObservationIgnored private var teamCreations: [String: TeamCreation] = [:]
    private(set) var oneCreation: SingleAgentCreation?
    @ObservationIgnored private var folderGeneration = 0
    private(set) var loadedOnce = false
    /// An agent a previous run made: the crew counts as made and nothing is made again.
    private(set) var adopted: Agent?

    init(server: ServerModel, subscriptions: SubscriptionsModel, preview: ReadyTeamPreview? = nil) {
        self.server = server
        self.subscriptions = subscriptions
        self.preview = preview
        workplaces = WorkspacesModel(server: server)
        if preview != nil { loadedOnce = true }
    }

    // MARK: catalog

    var languageCode: String { ModelDescription.currentLanguageCode }

    var load: Load {
        if preview != nil { return .ready }
        if let failure = bots.failure { return .failed(failure) }
        return bots.loaded || !server.supports("agent_templates") ? .ready : .loading
    }

    /// The ready teams this server can make, in the order of `ReadyTeamsLogic.ids`. None on an older daemon.
    var teams: [AgentBundle] {
        guard preview != nil || ReadyTeamsLogic.supported(server.supports) else { return [] }
        return ReadyTeamsLogic.teams(from: preview?.bundles ?? bots.bundles)
    }

    func members(of bundle: AgentBundle) -> [BotTemplate] {
        BundleLogic.members(of: bundle, templates: preview?.templates ?? bots.templates)
    }

    var selectedTeam: AgentBundle? {
        guard case .team(let id) = choice else { return nil }
        return teams.first { $0.id == id }
    }

    var selectedMembers: [BotTemplate] {
        selectedTeam.map(members(of:)) ?? []
    }

    var scheduleItems: [ReadyTeamsLogic.ScheduleItem] {
        ReadyTeamsLogic.scheduleItems(members: selectedMembers, languageCode: languageCode)
    }

    /// The runtimes that are installed and signed in: the only ones an agent can run on.
    var available: [RuntimeKind] { subscriptions.signedIn }

    var modelLine: String {
        guard let runtime, let id = ReadyTeamsLogic.model(runtime: runtime, models: models(for: runtime)) else {
            return L10n.ReadyTeam.modelDefault
        }
        return L10n.ReadyTeam.model(name: models(for: runtime).first { $0.id == id }?.name ?? id)
    }

    private func models(for runtime: RuntimeKind) -> [RuntimeModel] {
        server.runtimeModels[runtime.rawValue]?.models ?? []
    }

    // MARK: choosing

    /// The first read: the catalog, the home folder, the first team chosen (or one agent when there is no team).
    func start() async {
        if preview == nil {
            // The runtimes are read again: a relaunch can land here without the step before having asked.
            _ = try? await server.refreshRuntimes()
            await bots.load(from: server)
        }
        if home == nil { home = try? await server.list("~").path }
        await workplaces.load()
        runtime = BundleLogic.runtime(keeping: runtime, available: available)
        if choice == nil { select(teams.first.map { .team($0.id) } ?? .single) }
        loadedOnce = true
    }

    /// Reads the catalog again after a failed load.
    func reload() async {
        bots.reset()
        await start()
    }

    /// The runtimes can change while the step is open (a sign-in finishes): a choice that is still ready stays.
    func runtimesChanged() {
        runtime = BundleLogic.runtime(keeping: runtime, available: available)
    }

    func select(_ next: Choice) {
        guard next != choice else { return }
        choice = next
        folderCustomized = false
        enabled = []
        refreshFolder()
    }

    func chooseRuntime(_ kind: RuntimeKind) {
        guard !isLocked, available.contains(kind) else { return }
        runtime = kind
    }

    func setSchedule(_ key: String, on: Bool) {
        if on { enabled.insert(key) } else { enabled.remove(key) }
    }

    func setTemplate(_ next: AgentTemplate) {
        guard !isLocked else { return }
        template = next
        refreshFolder()
    }

    func setName(_ text: String) {
        guard !isLocked else { return }
        name = text
        refreshFolder()
    }

    /// The folder the person picked by hand is kept as it is when anything else changes.
    func setFolder(_ path: String) {
        guard !isLocked else { return }
        folder = path
        folderCustomized = true
        resolvingFolder = false
    }

    // MARK: single agent

    var workplaceReady: Bool {
        switch workplace {
        case .shared: true
        case .existing(let id): workplaces.containers.contains { $0.id == id }
        case .new: workplaces.canCreateSeparate && newWorkplace.canCreate
        }
    }

    /// Shared server, or a separate workplace. Switching to separate picks the first container, or a new one.
    func setSeparate(_ separate: Bool) {
        guard !isLocked else { return }
        guard separate else {
            workplace = .shared
            return
        }
        guard workplaces.canCreateSeparate, workplace == .shared else { return }
        workplace = workplaces.containers.first.map { .existing($0.id) } ?? .new
    }

    func chooseExisting(_ id: String) {
        guard !isLocked else { return }
        workplace = .existing(id)
    }

    func chooseNewWorkplace() {
        guard !isLocked else { return }
        workplace = .new
    }

    func setNewWorkplaceName(_ text: String) {
        guard !isLocked else { return }
        newWorkplace.name = text
    }

    var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? template.title : trimmed
    }

    var nameProblem: AgentNameRule.Problem? {
        AgentNameRule.problem(for: effectiveName, existing: server.agents.map(\.name))
    }

    // MARK: folder

    /// A folder of the crew is made by Bandito when the person did not pick one.
    var makesFolder: Bool { !folderCustomized }

    /// The default folder follows the choice until the person picks one; free of every agent's folder and of every
    /// folder already in `projects`. A stale answer (the choice changed while the listing came) is dropped.
    private func refreshFolder() {
        guard !folderCustomized, !isLocked, let home else { return }
        let seed: String
        switch choice {
        case .team(let id): seed = teams.first { $0.id == id }?.name(languageCode: languageCode) ?? "crew"
        case .single, nil: seed = effectiveName
        }
        let base = AgentFolder.defaultPath(home: home, name: seed)
        folder = base
        resolvingFolder = true
        folderGeneration += 1
        let generation = folderGeneration
        Task { [weak self] in await self?.resolveFolder(base: base, home: home, generation: generation) }
    }

    private func resolveFolder(base: String, home: String, generation: Int) async {
        var taken = Set(server.agents.map(\.cwd))
        let projects = home + "/projects"
        if let listing = try? await server.list(projects) {
            taken.formUnion(listing.entries.map { projects + "/" + $0.name })
        }
        guard generation == folderGeneration else { return }
        resolvingFolder = false
        guard !folderCustomized, !isLocked else { return }
        folder = AgentFolder.unique(base, taken: taken)
    }

    // MARK: making

    /// The crew was made in an earlier run (the flow remembers its first agent): it is shown as made.
    func adopt(_ agent: Agent) {
        adopted = agent
    }

    var teamCreation: TeamCreation? {
        guard case .team(let id) = choice else { return nil }
        return teamCreations[id]
    }

    /// An attempt began: the folder and the runtime stay as they were for every attempt after it.
    var isLocked: Bool {
        (teamCreation?.folder != nil) || oneCreation?.folder != nil
    }

    var isBusy: Bool {
        (teamCreation?.busy ?? false) || (oneCreation?.busy ?? false)
    }

    /// The crew (or the agent) exists in full.
    var isDone: Bool {
        if adopted != nil { return true }
        switch choice {
        case .team: return teamCreation?.isComplete ?? teamAlreadyThere
        case .single: return oneCreation?.agent != nil
        case nil: return false
        }
    }

    var failure: UserFacingMessage? {
        let text: String?
        switch choice {
        case .team: text = teamCreation?.failure
        case .single: text = oneCreation?.failure
        case nil: text = nil
        }
        return text.map { UserFacingMessage(text: $0, canRetry: true) }
    }

    var canCreate: Bool {
        guard !isBusy, !resolvingFolder, runtime != nil else { return false }
        switch choice {
        case .team:
            return ReadyTeamsLogic.canCreate(runtime: runtime, folder: folder, members: selectedMembers, busy: false)
                && !selectedMembers.isEmpty
        case .single:
            return nameProblem == nil && !folder.trimmingCharacters(in: .whitespaces).isEmpty && workplaceReady
        case nil:
            return false
        }
    }

    /// The agents that exist now, in the crew's order.
    var madeAgents: [Agent] {
        if let adopted { return [adopted] }
        switch choice {
        case .team:
            guard let creation = teamCreation else { return Array(existingMade.values).sorted { rank($0) < rank($1) } }
            return creation.members.compactMap { creation.made[$0.id] }
        case .single:
            return oneCreation?.agent.map { [$0] } ?? []
        case nil:
            return []
        }
    }

    /// The agents of the chosen team that are already on the server (by template): an earlier run made them, or this one
    /// did and the app was closed. Shown as made; Hire makes only the rest.
    var existingMade: [String: Agent] {
        guard case .team = choice else { return [:] }
        var found: [String: Agent] = [:]
        for member in selectedMembers {
            if let agent = server.agents.first(where: { $0.templateId == member.id }) { found[member.id] = agent }
        }
        return found
    }

    private var teamAlreadyThere: Bool {
        let members = selectedMembers
        return !members.isEmpty && existingMade.count == members.count
    }

    /// Some of the team is on the server and some is not, and nothing was made in this run yet: the step offers to make
    /// the rest or to go on.
    var isResumed: Bool {
        guard case .team = choice, teamCreation == nil, adopted == nil else { return false }
        return !existingMade.isEmpty && !teamAlreadyThere
    }

    private func rank(_ agent: Agent) -> Int {
        selectedMembers.firstIndex { $0.id == agent.templateId } ?? Int.max
    }

    /// The agent the first task goes to.
    var firstAgent: Agent? { madeAgents.first }

    /// The id of the ready team the person chose, or nil for one agent: the first task's suggestions follow it.
    var teamID: String? {
        if case .team(let id) = choice { return id }
        return nil
    }

    /// One tap: makes the crew, or only what is missing after a failed attempt. Returns the first agent when done.
    @discardableResult
    func create() async -> Agent? {
        guard canCreate, let runtime else { return nil }
        switch choice {
        case .team(let id):
            guard let bundle = teams.first(where: { $0.id == id }) else { return nil }
            let creation = teamCreations[id] ?? TeamCreation(
                server: server, bundle: bundle, members: members(of: bundle), runtime: runtime,
                model: ReadyTeamsLogic.model(runtime: runtime, models: models(for: runtime)), languageCode: languageCode,
                texts: CrewTexts.creation, alreadyMade: existingMade)
            teamCreations[id] = creation
            let path = folder, makes = makesFolder, server = server
            await creation.create(
                folder: { if makes { try await server.ensureFolder(path) }; return path },
                items: scheduleItems, enabled: enabled)
            if creation.isComplete { Telemetry.count(.agentCreate(.bundle)) }
            return creation.isComplete ? creation.firstAgent : nil
        case .single:
            let creation = oneCreation ?? SingleAgentCreation(server: server, describe: {
                WorkspaceText.failure($0) ?? UserFacingError.message(for: $0).text
            })
            oneCreation = creation
            let template = template
            let agentName = effectiveName
            let path = folder, makes = makesFolder, server = server
            let place = workplace, draft = newWorkplace
            let made = await creation.create(
                folder: { if makes { try await server.ensureFolder(path) }; return path },
                workplace: { try await WorkplaceCreation.prepare(place, new: draft, on: server) },
                build: { folder, workspaceID in
                    NewAgent(
                        name: agentName, role: template == .scratch ? "" : template.title, runtime: runtime, cwd: folder,
                        approvalMode: .risky, systemPrompt: template.instructions.isEmpty ? nil : template.instructions,
                        effort: template.effort, workspaceId: workspaceID)
                })
            if made { Telemetry.count(.agentCreate(template == .scratch ? .plain : .template)) }
            return made ? creation.agent : nil
        case nil:
            return nil
        }
    }
}
