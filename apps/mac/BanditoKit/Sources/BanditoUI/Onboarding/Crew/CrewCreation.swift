import BanditoKit
import BanditoL10n
import Foundation

/// The Mac's way to a folder that exists: `projects` is made when a fresh server has none.
extension ServerModel {
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

/// The texts of the creation on the Mac.
enum CrewTexts {
    static var creation: AgentCreationTexts {
        AgentCreationTexts(
            describe: { UserFacingError.message(for: $0).text },
            partial: { L10n.Onboarding.Crew.partial(made: String($0), total: String($1)) },
            noRuntime: L10n.Onboarding.Crew.noRuntime, none: L10n.Onboarding.Crew.noneMade)
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
