import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct SelectChoicesTests {
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    // MARK: Servers

    @Test func serverRowsKeepTheirOrderAndNameAndAddress() {
        let rows = [
            SelectChoices.ServerRow(id: idA, name: "vps-1", address: "10.0.0.1", isOnline: true, hasUpdate: false),
            SelectChoices.ServerRow(id: idB, name: "laptop", address: "This Mac", isOnline: false, hasUpdate: false),
        ]
        let options = SelectChoices.servers(rows, updateText: "Update available")
        #expect(options.map(\.value) == [idA, idB])
        #expect(options.map(\.title) == ["vps-1", "laptop"])
        #expect(options.map(\.subtitle) == ["10.0.0.1", "This Mac"])
        #expect(options.allSatisfy { $0.help == nil })
    }

    @Test func anUpdateIsSaidInTheSubtitleAndInTheHelp() {
        let rows = [
            SelectChoices.ServerRow(id: idA, name: "vps-1", address: "10.0.0.1", isOnline: true, hasUpdate: true)
        ]
        let option = SelectChoices.servers(rows, updateText: "Update available")[0]
        #expect(option.subtitle == "10.0.0.1 · Update available")
        #expect(option.help == "Update available")
    }

    // MARK: Workplaces

    @Test func sharedServerFirstThenContainersInOrder() {
        let options = SelectChoices.workplaces(
            sharedTitle: "Shared server", sharedEnabled: true,
            containers: [.init(id: "c1", name: "Forge box"), .init(id: "c2", name: "Scout")], currentID: "c2")
        #expect(options.map(\.value) == [Workspace.sharedID, "c1", "c2"])
        #expect(options.map(\.title) == ["Shared server", "Forge box", "Scout"])
    }

    @Test func theCurrentPlaceIsNotPickedAgainAndSharedIsOffOnTheSharedServer() {
        let inContainer = SelectChoices.workplaces(
            sharedTitle: "Shared", sharedEnabled: true,
            containers: [.init(id: "c1", name: "Forge box")], currentID: "c1")
        #expect(inContainer.map(\.isEnabled) == [true, false])

        let onShared = SelectChoices.workplaces(
            sharedTitle: "Shared", sharedEnabled: false,
            containers: [.init(id: "c1", name: "Forge box")], currentID: Workspace.sharedID)
        #expect(onShared.map(\.isEnabled) == [false, true])
    }

    @Test func aVanishedExistingPlaceBecomesANewOne() {
        #expect(SelectChoices.workplace(.existing("c1"), containerIDs: ["c1", "c2"]) == .existing("c1"))
        #expect(SelectChoices.workplace(.existing("gone"), containerIDs: ["c1"]) == .new)
        #expect(SelectChoices.workplace(.existing("gone"), containerIDs: []) == .new)
    }

    @Test func otherChoicesStayAsTheyAre() {
        #expect(SelectChoices.workplace(.shared, containerIDs: []) == .shared)
        #expect(SelectChoices.workplace(.new, containerIDs: ["c1"]) == .new)
    }

    // MARK: Languages

    @Test func systemComesFirstThenEachLanguageWithItsOwnNameAndItsLocalName() {
        let system = SelectOption(value: "system", title: "System")
        let options = SelectChoices.languages(
            system: system,
            entries: [(code: "ru", native: "Русский"), (code: "de", native: "Deutsch")],
            localizedName: { $0 == "ru" ? "Russian" : nil })
        #expect(options.map(\.value) == ["system", "ru", "de"])
        #expect(options.map(\.title) == ["System", "Русский", "Deutsch"])
        #expect(options.map(\.subtitle) == [nil, "Russian", nil])
    }

    @Test func noSystemOptionWhenNoneIsGiven() {
        let options = SelectChoices.languages(
            system: nil, entries: [(code: "en", native: "English")], localizedName: { _ in "English" })
        #expect(options.map(\.value) == ["en"])
    }

    // MARK: Approvals

    @Test func approvalActionsAreAllowAskDenyWithTheirTextAndIcons() {
        let options = SelectChoices.approvalActions(
            allow: .init(title: "Allow", subtitle: "Runs"),
            ask: .init(title: "Ask", subtitle: "Asks"),
            deny: .init(title: "Deny", subtitle: "Never"))
        #expect(options.map(\.value) == [.allow, .ask, .deny])
        #expect(options.map(\.title) == ["Allow", "Ask", "Deny"])
        #expect(options.map(\.subtitle) == ["Runs", "Asks", "Never"])
        #expect(options.map(\.icon) == ["checkmark.circle", "hand.raised", "xmark.octagon"])
    }

    @Test func scopesStartWithAllAgentsThenEachAgentById() {
        let options = SelectChoices.scopes(
            allAgentsTitle: "All agents",
            agents: [(id: "a1", name: "Forge", tint: nil), (id: "a2", name: "Scout", tint: nil)])
        #expect(options.map(\.value) == ["*", "a1", "a2"])
        #expect(options.map(\.title) == ["All agents", "Forge", "Scout"])
    }

    @Test func aScopeOfADeletedAgentFallsBackToAllAgents() {
        #expect(SelectChoices.scope("*", agentIDs: []) == "*")
        #expect(SelectChoices.scope("a1", agentIDs: ["a1", "a2"]) == "a1")
        #expect(SelectChoices.scope("a1", agentIDs: ["a2"]) == "*")
        #expect(SelectChoices.scope("a1", agentIDs: []) == "*")
    }
}
