import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the creation sheets need from a server: `ServerModel` in the app, a fake in the tests.
@MainActor
protocol AgentMaking: AnyObject {
    var agents: [Agent] { get }
    func makeFreeFolder(root: String, base: String) async throws -> String
    func createAgent(_ new: NewAgent) async throws -> Agent
    func createBundle(_ new: NewBundle) async throws -> BundleCreation
    /// Reads the agents of the server again into `agents`.
    func readAgentsNow() async throws
}

extension ServerModel: AgentMaking {
    func makeFreeFolder(root: String, base: String) async throws -> String {
        try await AgentFolders.makeFree(root: root, base: base, server: self)
    }
}

/// Makes a ready team and survives a failed attempt, as the Mac's sheet does. "Created" is judged by ids, never by the
/// clock or the error text:
/// - before every attempt the ids of the agents on the server are noted;
/// - an answer counts every entry that has an agent, even when the entry also has an error (a schedule that failed);
/// - when the request fails, the list is read again and the agents that are new since the snapshot are matched to the
///   positions of the team (by template, else by name). The agent may exist although the answer was lost.
/// A retry makes only the positions that are not created yet, in the same folder.
@MainActor
@Observable
final class TeamCreationModel {
    let bundle: AgentBundle
    let members: [BotTemplate]
    private let server: AgentMaking
    private let root: String
    private let runtime: RuntimeKind
    private let model: String?
    private let languageCode: String

    /// The team's folder, made on the first attempt and used by every attempt after it.
    private(set) var folder: String?
    /// The positions of the team whose agents exist.
    private(set) var madeTemplateIDs: Set<String> = []
    private(set) var failure: String?
    private(set) var busy = false
    /// Counts the complete teams (a haptic on each).
    private(set) var madeCount = 0

    init(
        server: AgentMaking, bundle: AgentBundle, members: [BotTemplate], root: String, runtime: RuntimeKind,
        model: String?, languageCode: String
    ) {
        self.server = server
        self.bundle = bundle
        self.members = members
        self.root = root
        self.runtime = runtime
        self.model = model
        self.languageCode = languageCode
    }

    var isComplete: Bool {
        members.allSatisfy { madeTemplateIDs.contains($0.id) }
    }

    /// Makes the team, or the positions still missing. Returns whether the team is complete.
    @discardableResult
    func create(items: [ReadyTeamsLogic.ScheduleItem], enabled: Set<String>) async -> Bool {
        guard !busy, !isComplete else { return isComplete }
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let path: String
            if let folder {
                path = folder
            } else {
                path = try await server.makeFreeFolder(
                    root: root, base: NewAgentFolderRules.folderName(for: bundle.name(languageCode: languageCode)))
                folder = path
            }
            guard var request = ReadyTeamsLogic.request(
                bundle: bundle, runtime: runtime, languageCode: languageCode, model: model, folder: path,
                items: items, enabled: enabled)
            else {
                failure = L10n.AgentSheet.statusNotInstalled
                return false
            }
            request.templates = members.map(\.id).filter { !madeTemplateIDs.contains($0) }
            let before = Set(server.agents.map(\.id))
            do {
                let made = try await server.createBundle(request)
                for entry in made.agents where entry.agent != nil {
                    madeTemplateIDs.insert(entry.templateId)
                }
                if !isComplete {
                    failure = made.agents.compactMap(\.error).first
                }
            } catch {
                failure = AgentForms.errorText(error)
                await markFreshAgents(since: before)
            }
        } catch {
            failure = AgentForms.errorText(error)
        }
        if isComplete {
            failure = nil
            madeCount += 1
        } else if failure == nil {
            failure = L10n.Market.Bundle.resultTitle(
                created: String(madeTemplateIDs.count), total: String(members.count))
        }
        return isComplete
    }

    /// Reads the server's agents again and marks the positions that a new agent (one not in `before`) stands for.
    private func markFreshAgents(since before: Set<String>) async {
        _ = try? await server.readAgentsNow()
        let fresh = server.agents.filter { !before.contains($0.id) }
        for agent in fresh {
            if let member = members.first(where: { $0.id == agent.templateId }) {
                madeTemplateIDs.insert(member.id)
            } else if let member = members.first(where: {
                !madeTemplateIDs.contains($0.id) && $0.name(languageCode: languageCode) == agent.name
            }) {
                madeTemplateIDs.insert(member.id)
            }
        }
    }
}

/// Makes one agent, keeping its folder: a retry after a failed request uses the same folder and never makes a second
/// agent. A lost answer is looked for on the server first: a new agent with the same name is this agent.
@MainActor
@Observable
final class OneAgentCreation {
    private let server: AgentMaking
    private let root: String
    private let base: String

    /// The agent's folder, made by the first attempt and used by every attempt after it.
    private(set) var folder: String?
    /// The agent the server made, once it did (or once a lost answer showed it on the server).
    private(set) var createdAgentID: String?
    private(set) var failure: String?
    private(set) var busy = false
    /// Counts the agents made (a haptic on each).
    private(set) var madeCount = 0

    init(server: AgentMaking, root: String, base: String) {
        self.server = server
        self.root = root
        self.base = base
    }

    /// Makes the agent in `build`'s request, with the folder the first attempt made. Returns whether it exists now.
    @discardableResult
    func create(build: (String) -> NewAgent) async -> Bool {
        guard !busy else { return false }
        if createdAgentID != nil { return true }
        busy = true
        defer { busy = false }
        failure = nil
        do {
            let path: String
            if let folder {
                path = folder
            } else {
                path = try await server.makeFreeFolder(root: root, base: base)
                folder = path
            }
            let new = build(path)
            let before = Set(server.agents.map(\.id))
            do {
                let agent = try await server.createAgent(new)
                createdAgentID = agent.id
            } catch {
                // The answer may be lost after the daemon made the agent: the list decides, not the error.
                _ = try? await server.readAgentsNow()
                if let fresh = server.agents.first(where: { !before.contains($0.id) && $0.name == new.name }) {
                    createdAgentID = fresh.id
                } else {
                    failure = AgentForms.errorText(error)
                    return false
                }
            }
            madeCount += 1
            return true
        } catch {
            failure = AgentForms.errorText(error)
            return false
        }
    }
}
