import BanditoKit
import BanditoL10n
import Foundation

/// The rules of the ready teams (bundles of agents offered on the team's home and on the empty team): which bundles
/// are offered, what the preview lists, and the request that makes the team. Pure, so the tests hold each rule.
enum ReadyTeamsLogic {
    /// The bundles offered as ready teams, in this order: a web project, the server on duty, the morning summary,
    /// the documentation. The other bundles stay on the Marketplace's Bots page.
    static let ids = ["web-project", "server-duty", "morning-summary", "docs-upkeep"]

    /// The daemon features a ready team needs: the bundles, and their model, shared folder and schedules (an older
    /// daemon would drop the folder silently, so it is not offered a team at all).
    static func supported(_ supports: (String) -> Bool) -> Bool {
        supports("agent_bundles") && supports("bundle_schedules")
    }

    /// The ready teams the catalog has, in `ids` order.
    static func teams(from bundles: [AgentBundle]) -> [AgentBundle] {
        ids.compactMap { id in bundles.first { $0.id == id } }
    }

    /// The key of a template's schedule in `NewBundle.schedules`.
    static func scheduleKey(templateID: String, index: Int) -> String {
        "\(templateID):\(index)"
    }

    /// One schedule of the team, as the preview lists it: the agent, when, and its key.
    struct ScheduleItem: Identifiable, Equatable {
        let key: String
        let agentName: String
        /// "Every day at 8:00 AM", or the cron itself when it is not of a plain kind.
        let when: String
        let isCron: Bool
        var id: String { key }
    }

    static func scheduleItems(members: [BotTemplate], languageCode: String) -> [ScheduleItem] {
        members.flatMap { member in
            member.schedules.enumerated().map { index, schedule in
                let words = BotScheduleWords.words(cron: schedule.cron, languageCode: languageCode)
                return ScheduleItem(
                    key: scheduleKey(templateID: member.id, index: index),
                    agentName: member.name(languageCode: languageCode),
                    when: words ?? schedule.cron, isCron: words == nil)
            }
        }
    }

    /// What the agent may use, by the chip names the app already has. Unknown names of a newer daemon are left out.
    static func permissions(of template: BotTemplate) -> [AgentCapability] {
        AgentCapability.allCases.filter { template.capabilities.contains($0.rawValue) }
    }

    /// A team of several agents works in one project folder, so the folder is needed; one agent may keep its own.
    static func folderRequired(members: [BotTemplate]) -> Bool {
        members.count > 1
    }

    static func canCreate(runtime: RuntimeKind?, folder: String, members: [BotTemplate], busy: Bool) -> Bool {
        guard !busy, runtime != nil, !members.isEmpty else { return false }
        return !folderRequired(members: members) || !folder.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The model the team starts on: Haiku on Claude Code (as a new agent does, `NewAgentModelRules`), else the
    /// runtime's own default (nil).
    static func model(runtime: RuntimeKind, models: [RuntimeModel]) -> String? {
        NewAgentModelRules.preferredModel(runtime: runtime, models: models)
    }

    /// The body of `agents.create_bundle`. Every schedule of the team is made and only the ones in `enabled` start on;
    /// with none to make, `schedules` is left out. Nil without a runtime.
    static func request(
        bundle: AgentBundle, runtime: RuntimeKind?, languageCode: String, model: String?, folder: String,
        items: [ScheduleItem], enabled: Set<String>
    ) -> NewBundle? {
        guard let runtime else { return nil }
        let cwd = folder.trimmingCharacters(in: .whitespaces)
        return NewBundle(
            bundleId: bundle.id, language: CatalogLanguage.requestCode(languageCode), runtime: runtime.rawValue,
            model: model, cwd: cwd.isEmpty ? nil : cwd,
            schedules: items.isEmpty ? nil : items.map(\.key).filter(enabled.contains).sorted())
    }
}
