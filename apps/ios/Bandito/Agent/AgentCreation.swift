import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the creation sheets need from a server: `ServerModel` in the app, a fake in the tests.
@MainActor
protocol AgentMaking: AgentCreationServer {
    func makeFreeFolder(root: String, base: String) async throws -> String
}

extension ServerModel: AgentMaking {
    func makeFreeFolder(root: String, base: String) async throws -> String {
        try await AgentFolders.makeFree(root: root, base: base, server: self)
    }
}

/// The algorithm is shared with the Mac (`TeamCreation`, `SingleAgentCreation` in BanditoKit): ids decide what was made,
/// never the clock or the error text; a retry makes only what is missing, in the same folder. These wrappers give it
/// the iPhone's folder rule (the first free folder under the agents folder) and texts.
@MainActor
@Observable
final class TeamCreationModel {
    private let core: TeamCreation
    private let server: AgentMaking
    private let root: String
    private let folderBase: String

    init(
        server: AgentMaking, bundle: AgentBundle, members: [BotTemplate], root: String, runtime: RuntimeKind,
        model: String?, languageCode: String
    ) {
        self.server = server
        self.root = root
        folderBase = NewAgentFolderRules.folderName(for: bundle.name(languageCode: languageCode))
        core = TeamCreation(
            server: server, bundle: bundle, members: members, runtime: runtime, model: model, languageCode: languageCode,
            texts: AgentCreationTexts(
                describe: { AgentForms.errorText($0) },
                partial: { L10n.Market.Bundle.resultTitle(created: String($0), total: String($1)) },
                noRuntime: L10n.AgentSheet.statusNotInstalled, none: L10n.Market.Bundle.Status.notMade))
    }

    var bundle: AgentBundle { core.bundle }
    var members: [BotTemplate] { core.members }
    var folder: String? { core.folder }
    var madeTemplateIDs: Set<String> { core.madeTemplateIDs }
    var failure: String? { core.failure }
    var busy: Bool { core.busy }
    var madeCount: Int { core.madeCount }
    var isComplete: Bool { core.isComplete }

    /// Makes the team, or the positions still missing. Returns whether the team is complete.
    @discardableResult
    func create(items: [ReadyTeamsLogic.ScheduleItem], enabled: Set<String>) async -> Bool {
        let server = server, root = root, base = folderBase
        return await core.create(
            folder: { try await server.makeFreeFolder(root: root, base: base) }, items: items, enabled: enabled)
    }
}

/// Makes one agent, keeping its folder: see `SingleAgentCreation`.
@MainActor
@Observable
final class OneAgentCreation {
    private let core: SingleAgentCreation
    private let server: AgentMaking
    private let root: String
    private let base: String

    init(server: AgentMaking, root: String, base: String) {
        self.server = server
        self.root = root
        self.base = base
        core = SingleAgentCreation(server: server, describe: { AgentForms.errorText($0) })
    }

    var folder: String? { core.folder }
    var createdAgentID: String? { core.agent?.id }
    var failure: String? { core.failure }
    var busy: Bool { core.busy }
    var madeCount: Int { core.madeCount }

    /// Makes the agent in `build`'s request, with the folder the first attempt made. Returns whether it exists now.
    @discardableResult
    func create(build: @escaping (String) -> NewAgent) async -> Bool {
        let server = server, root = root, base = base
        return await core.create(
            folder: { try await server.makeFreeFolder(root: root, base: base) }, build: { folder, _ in build(folder) })
    }
}
