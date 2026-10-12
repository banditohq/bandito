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
    func readAgentsNow() async throws
}

extension ServerModel: AgentMaking {
    func makeFreeFolder(root: String, base: String) async throws -> String {
        try await AgentFolders.makeFree(root: root, base: base, server: self)
    }
}

/// Makes a ready team, and survives a partial failure as the Mac's sheet does: the folder is made once and kept, the
/// agents already made are not asked for again, and a retry makes only the ones still missing.
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
    /// The templates whose agents exist: made by this sheet, or found on the server after a failed request.
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

    /// Makes the team, or what of it is still missing. Returns whether the team is complete.
    @discardableResult
    func create(items: [ReadyTeamsLogic.ScheduleItem], enabled: Set<String>) async -> Bool {
        guard !busy, !isComplete else { return isComplete }
        busy = true
        defer { busy = false }
        failure = nil
        let attemptStart = Int64(Date().timeIntervalSince1970 * 1000)
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
            let made = try await server.createBundle(request)
            for entry in made.agents where entry.agent != nil && entry.error == nil {
                madeTemplateIDs.insert(entry.templateId)
            }
        } catch {
            failure = AgentForms.errorText(error)
            // The daemon may have made some agents before the request failed: read the list first.
            try? await server.readAgentsNow()
            for member in members where server.agents.contains(where: {
                $0.templateId == member.id && $0.createdAt >= attemptStart
            }) {
                madeTemplateIDs.insert(member.id)
            }
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
}

/// Makes one agent, keeping the folder it made: a retry after a failed request uses the same folder and makes no second.
@MainActor
@Observable
final class OneAgentCreation {
    private let server: AgentMaking
    private let root: String
    private let base: String

    /// The agent's folder, made by the first attempt and used by every attempt after it.
    private(set) var folder: String?
    /// The agent the server made, once it did.
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

    /// Makes the agent in `build`'s request, with the folder the first attempt made. Returns whether it was made.
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
            let agent = try await server.createAgent(build(path))
            createdAgentID = agent.id
            madeCount += 1
            return true
        } catch {
            failure = AgentForms.errorText(error)
            return false
        }
    }
}
