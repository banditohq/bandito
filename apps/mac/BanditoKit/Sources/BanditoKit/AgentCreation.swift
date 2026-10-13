import Foundation
import Observation

/// What the creation of agents needs from a server: `ServerModel` in the apps, a fake in the tests.
@MainActor
public protocol AgentCreationServer: AnyObject {
    var agents: [Agent] { get }
    func createAgent(_ new: NewAgent) async throws -> Agent
    func createBundle(_ new: NewBundle) async throws -> BundleCreation
    /// Reads the agents of the server again into `agents`.
    func readAgentsNow() async throws
}

extension ServerModel: AgentCreationServer {}

/// The texts a creation says in its `failure`; the apps pass their own (this module has no say about the interface).
public struct AgentCreationTexts {
    /// What a thrown error is told as.
    public var describe: (Error) -> String
    /// Some of a team exists: "{made} of {total} are ready".
    public var partial: (_ made: Int, _ total: Int) -> String
    /// No runtime can make the team.
    public var noRuntime: String
    /// Nothing was made and nothing is known about why.
    public var none: String

    public init(
        describe: @escaping (Error) -> String, partial: @escaping (Int, Int) -> String,
        noRuntime: String, none: String
    ) {
        self.describe = describe
        self.partial = partial
        self.noRuntime = noRuntime
        self.none = none
    }
}

/// Makes a ready team and survives a failed attempt. "Made" is judged by ids, never by the clock (the server's clock may
/// be ahead or behind) or by the error text:
/// - before every attempt the ids of the agents on the server are noted;
/// - an answer counts every entry that has an agent, even when the entry also has an error (a schedule that failed);
/// - when the request fails, the list is read again and the agents that are new since the snapshot are matched to the
///   positions of the team (by template, else by name). The agent may exist although the answer was lost.
/// A retry asks for the positions that are not made yet only, in the same folder, and makes the folder once.
@MainActor
@Observable
public final class TeamCreation {
    public let bundle: AgentBundle
    public let members: [BotTemplate]
    @ObservationIgnored private let server: AgentCreationServer
    @ObservationIgnored private let runtime: RuntimeKind
    @ObservationIgnored private let model: String?
    @ObservationIgnored private let languageCode: String
    @ObservationIgnored private let texts: AgentCreationTexts

    /// The team's folder, fixed by the first attempt that got one and used by every attempt after it.
    public private(set) var folder: String?
    /// The agents that exist, by the template that stands for them.
    public private(set) var made: [String: Agent] = [:]
    /// What the daemon said went wrong after an agent was made (a schedule, a skill), by template.
    public private(set) var problems: [String: String] = [:]
    /// The integrations the team lists that are not connected (each once).
    public private(set) var missingIntegrations: [MissingIntegration] = []
    public private(set) var failure: String?
    public private(set) var busy = false
    /// Counts the complete teams (a haptic on each).
    public private(set) var madeCount = 0

    public init(
        server: AgentCreationServer, bundle: AgentBundle, members: [BotTemplate], runtime: RuntimeKind, model: String?,
        languageCode: String, texts: AgentCreationTexts, alreadyMade: [String: Agent] = [:]
    ) {
        self.server = server
        self.bundle = bundle
        self.members = members
        self.runtime = runtime
        self.model = model
        self.languageCode = languageCode
        self.texts = texts
        made = alreadyMade.filter { pair in members.contains { $0.id == pair.key } }
    }

    public var madeTemplateIDs: Set<String> { Set(made.keys) }

    /// What exists now as the daemon's answer would show it: one entry per made position, in the team's order.
    public var result: BundleCreation {
        BundleCreation(
            agents: members.compactMap { member in
                made[member.id].map { BundleEntry(templateId: member.id, agent: $0, error: problems[member.id]) }
            },
            missingIntegrations: missingIntegrations)
    }

    public var isComplete: Bool {
        !members.isEmpty && members.allSatisfy { made[$0.id] != nil }
    }

    /// The first agent of the team in the team's order: the first task goes to it.
    public var firstAgent: Agent? {
        members.lazy.compactMap { self.made[$0.id] }.first
    }

    /// Makes the team, or the positions still missing. `folder` makes (or picks) the team's folder and returns its path;
    /// it runs until it succeeds once, and never again after that. Returns whether the team is complete.
    @discardableResult
    public func create(
        folder makeFolder: () async throws -> String, items: [ReadyTeamsLogic.ScheduleItem], enabled: Set<String>
    ) async -> Bool {
        guard !busy, !isComplete else { return isComplete }
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let path: String
            if let folder {
                path = folder
            } else {
                path = try await makeFolder()
                folder = path
            }
            guard var request = ReadyTeamsLogic.request(
                bundle: bundle, runtime: runtime, languageCode: languageCode, model: model, folder: path,
                items: items, enabled: enabled)
            else {
                failure = texts.noRuntime
                return false
            }
            request.templates = members.map(\.id).filter { made[$0] == nil }
            let before = Set(server.agents.map(\.id))
            do {
                let answer = try await server.createBundle(request)
                for entry in answer.agents {
                    if let agent = entry.agent {
                        made[entry.templateId] = agent
                        problems[entry.templateId] = entry.error
                    }
                }
                for item in answer.missingIntegrations where !missingIntegrations.contains(where: { $0.id == item.id }) {
                    missingIntegrations.append(item)
                }
                if !isComplete { failure = answer.agents.compactMap(\.error).first }
            } catch {
                failure = texts.describe(error)
                await markFresh(since: before)
            }
        } catch {
            failure = texts.describe(error)
        }
        if isComplete {
            failure = nil
            madeCount += 1
        } else if !made.isEmpty && failure == nil {
            failure = texts.partial(made.count, members.count)
        } else if failure == nil {
            failure = texts.none
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

/// Makes one agent, keeping its folder and its workplace: a retry after a failed request uses the same folder, makes no
/// second container, and never makes a second agent. A lost answer is looked for on the server first: a new agent with
/// the same name (and folder) is this agent.
@MainActor
@Observable
public final class SingleAgentCreation {
    @ObservationIgnored private let server: AgentCreationServer
    @ObservationIgnored private let describe: (Error) -> String

    public private(set) var folder: String?
    /// The container made for the agent (or the one chosen), fixed by the first attempt that got one.
    public private(set) var workspaceID: String?
    private var workspaceDone = false
    /// The agent the server made, once it did (or once a lost answer showed it on the server).
    public private(set) var agent: Agent?
    public private(set) var failure: String?
    public private(set) var busy = false
    public private(set) var madeCount = 0

    public init(server: AgentCreationServer, describe: @escaping (Error) -> String) {
        self.server = server
        self.describe = describe
    }

    /// Makes the agent of `build`'s request. `folder` makes the folder (once), `workplace` makes the container (once) and
    /// returns its id, nil for the shared server. Returns whether the agent exists now.
    @discardableResult
    public func create(
        folder makeFolder: () async throws -> String, workplace: () async throws -> String? = { nil },
        build: (_ folder: String, _ workspaceID: String?) -> NewAgent
    ) async -> Bool {
        guard !busy else { return false }
        if agent != nil { return true }
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let path: String
            if let folder {
                path = folder
            } else {
                path = try await makeFolder()
                folder = path
            }
            if !workspaceDone {
                workspaceID = try await workplace()
                workspaceDone = true
            }
            let new = build(path, workspaceID)
            let before = Set(server.agents.map(\.id))
            do {
                agent = try await server.createAgent(new)
            } catch {
                // The answer may be lost after the daemon made the agent: the list decides, not the error.
                _ = try? await server.readAgentsNow()
                if let fresh = server.agents.first(where: {
                    !before.contains($0.id) && $0.name == new.name && $0.cwd == new.cwd
                }) {
                    agent = fresh
                } else {
                    failure = describe(error)
                    return false
                }
            }
            madeCount += 1
            return true
        } catch {
            failure = describe(error)
            return false
        }
    }
}
