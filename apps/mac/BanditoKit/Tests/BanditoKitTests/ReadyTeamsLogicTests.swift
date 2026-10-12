import BanditoKit
import Foundation
import Testing

@testable import BanditoKit

/// The rules of the ready teams: which are offered, the preview's lists and the request that makes the team.
@Suite struct ReadyTeamsLogicTests {
    private func bundle(_ id: String, templates: [String] = []) -> AgentBundle {
        AgentBundle(id: id, nameEn: id, nameRu: id, templates: templates)
    }

    private func template(_ id: String, schedules: [String] = [], capabilities: [String] = []) -> BotTemplate {
        BotTemplate(
            id: id, nameEn: id.capitalized, nameRu: id, schedules: schedules.map { BotSchedule(cron: $0) },
            capabilities: capabilities)
    }

    @Test func theOfferedTeamsAreTheFourInTheirOrderAndOnlyThoseTheCatalogHas() {
        let all = ["devops", "docs-upkeep", "startup-team", "web-project", "morning-summary"].map { bundle($0) }
        #expect(ReadyTeamsLogic.teams(from: all).map(\.id) == ["web-project", "morning-summary", "docs-upkeep"])
        #expect(ReadyTeamsLogic.teams(from: []).isEmpty)
    }

    @Test func aTeamNeedsTheDaemonsBundleOptions() {
        #expect(ReadyTeamsLogic.supported { ["agent_bundles", "bundle_schedules"].contains($0) })
        #expect(!ReadyTeamsLogic.supported { $0 == "agent_bundles" })
        #expect(!ReadyTeamsLogic.supported { _ in false })
    }

    @Test func theScheduleListHasOneItemPerScheduleWithAKeyAndWords() {
        let members = [
            template("dev"),
            template("watch", schedules: ["0 8,14,20 * * *"]),
            template("brief", schedules: ["0 8 * * 1-5", "*/10 * * * *"]),
        ]
        let items = ReadyTeamsLogic.scheduleItems(members: members, languageCode: "en")
        #expect(items.map(\.key) == ["watch:0", "brief:0", "brief:1"])
        #expect(items[0].isCron == false && items[1].isCron == false)
        #expect(items[2].isCron && items[2].when == "*/10 * * * *")
    }

    @Test func permissionsAreTheKnownCapabilitiesInTheChipOrder() {
        let t = template("x", capabilities: ["team", "files", "terminal", "from-the-future"])
        #expect(ReadyTeamsLogic.permissions(of: t) == [.terminal, .files, .team])
        #expect(ReadyTeamsLogic.permissions(of: template("y")).isEmpty)
    }

    @Test func aTeamOfSeveralNeedsOneFolderAndASingleAgentDoesNot() {
        let team = [template("a"), template("b")]
        let single = [template("a")]
        #expect(ReadyTeamsLogic.folderRequired(members: team))
        #expect(!ReadyTeamsLogic.folderRequired(members: single))
        #expect(!ReadyTeamsLogic.canCreate(runtime: .claude, folder: "  ", members: team, busy: false))
        #expect(ReadyTeamsLogic.canCreate(runtime: .claude, folder: "/srv/shop", members: team, busy: false))
        #expect(ReadyTeamsLogic.canCreate(runtime: .claude, folder: "", members: single, busy: false))
        #expect(!ReadyTeamsLogic.canCreate(runtime: nil, folder: "/srv/shop", members: team, busy: false))
        #expect(!ReadyTeamsLogic.canCreate(runtime: .claude, folder: "/srv/shop", members: team, busy: true))
        #expect(!ReadyTeamsLogic.canCreate(runtime: .claude, folder: "/srv/shop", members: [], busy: false))
    }

    @Test func theModelIsHaikuOnClaudeAndNothingElsewhere() {
        let models = [
            RuntimeModel(id: "opus", name: "Opus 5.5"), RuntimeModel(id: "haiku", name: "Haiku 5.5"),
        ]
        #expect(ReadyTeamsLogic.model(runtime: .claude, models: models) == "haiku")
        #expect(ReadyTeamsLogic.model(runtime: .codex, models: models) == nil)
        #expect(ReadyTeamsLogic.model(runtime: .claude, models: []) == nil)
    }

    @Test func theRequestSendsTheConfirmedSchedulesTheFolderAndTheModel() throws {
        let items = ReadyTeamsLogic.scheduleItems(
            members: [template("watch", schedules: ["0 8 * * *"]), template("brief", schedules: ["0 9 * * *"])],
            languageCode: "en")
        let request = try #require(
            ReadyTeamsLogic.request(
                bundle: bundle("web-project"), runtime: .claude, languageCode: "pt-br", model: "haiku",
                folder: " /srv/shop ", items: items, enabled: ["brief:0", "other:3"]))
        #expect(request.bundleId == "web-project")
        #expect(request.language == "pt-BR")
        #expect(request.runtime == "claude")
        #expect(request.model == "haiku")
        #expect(request.cwd == "/srv/shop")
        #expect(request.schedules == ["brief:0"], "a key that is not a schedule of the team is dropped")
    }

    @Test func nothingConfirmedIsAnEmptyListAndNoSchedulesIsNoList() throws {
        let items = ReadyTeamsLogic.scheduleItems(members: [template("watch", schedules: ["0 8 * * *"])], languageCode: "en")
        let off = try #require(
            ReadyTeamsLogic.request(
                bundle: bundle("server-duty"), runtime: .claude, languageCode: "en", model: nil, folder: "", items: items,
                enabled: []))
        #expect(off.schedules == [], "every schedule is made, all off")
        #expect(off.cwd == nil && off.model == nil)
        let none = try #require(
            ReadyTeamsLogic.request(
                bundle: bundle("docs"), runtime: .claude, languageCode: "en", model: nil, folder: "", items: [], enabled: []))
        #expect(none.schedules == nil)
        #expect(
            ReadyTeamsLogic.request(
                bundle: bundle("docs"), runtime: nil, languageCode: "en", model: nil, folder: "", items: [], enabled: [])
                == nil)
    }
}
