import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the "Hire your first crew" step needs from a server: `ServerModel` in the app, a fake in the tests.
@MainActor
protocol CrewMaking: AnyObject {
    var agents: [Agent] { get }
    /// Makes `path` when it is not there yet, and the folders above it that are missing (`projects`).
    func ensureFolder(_ path: String) async throws
    func createAgent(_ new: NewAgent) async throws -> Agent
    func createBundle(_ new: NewBundle) async throws -> BundleCreation
    /// Reads the agents of the server again into `agents`.
    func readAgentsNow() async throws
}

extension ServerModel: CrewMaking {
    func ensureFolder(_ path: String) async throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        do {
            let listing = try await list(parent)
            if listing.entries.contains(where: { $0.name == leaf }) { return }
        } catch {
            // The folder above is missing too (a fresh server has no `projects`): make that one first.
            guard parent != path, parent != "/" else { throw error }
            try await ensureFolder(parent)
        }
        _ = try await mkdir(path)
    }
}

/// Makes a ready team and survives a failed attempt. "Made" is judged by ids, never by the clock or the error text:
/// - before every attempt the ids of the agents on the server are noted;
/// - an answer counts every entry that has an agent, even when the entry also has an error (a schedule that failed);
/// - when the request fails, the list is read again and the agents that are new since the snapshot are matched to the
///   positions of the team (by template, else by name). The agent may exist although the answer was lost.
/// A retry asks for the positions that are not made yet only, in the same folder, and makes the folder once.
@MainActor
@Observable
final class TeamCreation {
    let bundle: AgentBundle
    let members: [BotTemplate]
    @ObservationIgnored private let server: CrewMaking
    @ObservationIgnored private let runtime: RuntimeKind
    @ObservationIgnored private let model: String?
    @ObservationIgnored private let languageCode: String
    @ObservationIgnored private let describe: (Error) -> UserFacingMessage

    /// The team's folder, fixed by the first attempt and used by every attempt after it.
    private(set) var folder: String?
    /// Whether the folder was made (the attempt that makes it comes first, and only once).
    private(set) var folderMade = false
    /// The agents that exist, by the template that stands for them.
    private(set) var made: [String: Agent] = [:]
    private(set) var failure: UserFacingMessage?
    private(set) var busy = false

    init(
        server: CrewMaking, bundle: AgentBundle, members: [BotTemplate], runtime: RuntimeKind, model: String?,
        languageCode: String, describe: @escaping (Error) -> UserFacingMessage = { UserFacingError.message(for: $0) }
    ) {
        self.server = server
        self.bundle = bundle
        self.members = members
        self.runtime = runtime
        self.model = model
        self.languageCode = languageCode
        self.describe = describe
    }

    var isComplete: Bool {
        !members.isEmpty && members.allSatisfy { made[$0.id] != nil }
    }

    /// The first agent of the team in the team's order: the first task goes to it.
    var firstAgent: Agent? {
        members.lazy.compactMap { self.made[$0.id] }.first
    }

    /// Makes the team, or the positions still missing. `makeFolder` is true for a folder Bandito chose (it is made on
    /// the server once); a folder the person picked exists already. Returns whether the team is complete.
    @discardableResult
    func create(
        folder wanted: String, makeFolder: Bool, items: [ReadyTeamsLogic.ScheduleItem], enabled: Set<String>
    ) async -> Bool {
        guard !busy, !isComplete else { return isComplete }
        busy = true
        defer { busy = false }
        failure = nil
        if folder == nil { folder = wanted }
        let path = folder ?? wanted
        do {
            if makeFolder, !folderMade {
                try await server.ensureFolder(path)
                folderMade = true
            }
            guard var request = ReadyTeamsLogic.request(
                bundle: bundle, runtime: runtime, languageCode: languageCode, model: model, folder: path,
                items: items, enabled: enabled)
            else {
                failure = UserFacingMessage(text: L10n.Onboarding.Crew.noRuntime)
                return false
            }
            request.templates = members.map(\.id).filter { made[$0] == nil }
            let before = Set(server.agents.map(\.id))
            do {
                let answer = try await server.createBundle(request)
                for entry in answer.agents {
                    if let agent = entry.agent { made[entry.templateId] = agent }
                }
            } catch {
                failure = describe(error)
                await markFresh(since: before)
            }
        } catch {
            failure = describe(error)
        }
        if isComplete {
            failure = nil
        } else if !made.isEmpty {
            // Some of the team exists: the retry makes the rest, and the person is told so in plain words.
            failure = UserFacingMessage(
                text: L10n.Onboarding.Crew.partial(made: String(made.count), total: String(members.count)),
                canRetry: true)
        } else if failure == nil {
            failure = UserFacingMessage(text: L10n.Onboarding.Crew.noneMade, canRetry: true)
        }
        return isComplete
    }

    /// Reads the agents again and marks the positions that a new agent (one not in `before`) stands for.
    private func markFresh(since before: Set<String>) async {
        _ = try? await server.readAgentsNow()
        for agent in server.agents where !before.contains(agent.id) {
            if let member = members.first(where: { $0.id == agent.templateId }) {
                if made[member.id] == nil { made[member.id] = agent }
            } else if let member = members.first(where: {
                made[$0.id] == nil && $0.name(languageCode: languageCode) == agent.name
            }) {
                made[member.id] = agent
            }
        }
    }
}

/// Makes one agent and keeps its folder: a retry after a failed request uses the same folder and never makes a second
/// agent. A lost answer is looked for on the server first: a new agent with the same name and folder is this agent.
@MainActor
@Observable
final class OneAgentCreation {
    @ObservationIgnored private let server: CrewMaking
    @ObservationIgnored private let describe: (Error) -> UserFacingMessage

    private(set) var folder: String?
    private(set) var folderMade = false
    /// The agent the server made, once it did (or once a lost answer showed it on the server).
    private(set) var agent: Agent?
    private(set) var failure: UserFacingMessage?
    private(set) var busy = false

    init(server: CrewMaking, describe: @escaping (Error) -> UserFacingMessage = { UserFacingError.message(for: $0) }) {
        self.server = server
        self.describe = describe
    }

    /// Makes the agent of `build`'s request in the folder the first attempt fixed. Returns whether it exists now.
    @discardableResult
    func create(folder wanted: String, makeFolder: Bool, build: (String) -> NewAgent) async -> Bool {
        guard !busy else { return false }
        if agent != nil { return true }
        busy = true
        defer { busy = false }
        failure = nil
        if folder == nil { folder = wanted }
        let path = folder ?? wanted
        do {
            if makeFolder, !folderMade {
                try await server.ensureFolder(path)
                folderMade = true
            }
            let new = build(path)
            let before = Set(server.agents.map(\.id))
            do {
                agent = try await server.createAgent(new)
            } catch {
                // The answer may be lost after the daemon made the agent: the list decides, not the error.
                _ = try? await server.readAgentsNow()
                if let fresh = server.agents.first(where: { !before.contains($0.id) && $0.name == new.name && $0.cwd == new.cwd }) {
                    agent = fresh
                } else {
                    failure = describe(error)
                    return false
                }
            }
            return true
        } catch {
            failure = describe(error)
            return false
        }
    }
}

/// The four suggestions of the first task, written for the crew the person hired (and for one agent).
enum FirstTaskSuggestions {
    enum Prompt: String, CaseIterable, Sendable {
        case lookAround, tests, disk, logs, summary, docs, introduce

        var text: String {
            switch self {
            case .lookAround: L10n.Onboarding.Task.Suggest.lookAround
            case .tests: L10n.Onboarding.Task.Suggest.tests
            case .disk: L10n.Onboarding.Task.Suggest.disk
            case .logs: L10n.Onboarding.Task.Suggest.logs
            case .summary: L10n.Onboarding.Task.Suggest.summary
            case .docs: L10n.Onboarding.Task.Suggest.docs
            case .introduce: L10n.Onboarding.Task.Suggest.introduce
            }
        }
    }

    /// Four prompts for a ready team by its bundle id; `nil` (one agent) and an unknown team get the general four.
    static func prompts(forTeam id: String?) -> [Prompt] {
        switch id {
        case "web-project": [.lookAround, .tests, .docs, .introduce]
        case "server-duty": [.disk, .logs, .summary, .introduce]
        case "morning-summary": [.summary, .lookAround, .disk, .introduce]
        case "docs-upkeep": [.docs, .lookAround, .summary, .introduce]
        default: [.lookAround, .disk, .summary, .introduce]
        }
    }
}
