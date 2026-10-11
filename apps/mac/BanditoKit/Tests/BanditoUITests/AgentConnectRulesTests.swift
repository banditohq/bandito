import BanditoKit
import Testing

@testable import BanditoUI

/// What the "agent needs a service" card does when Connect is pressed, and what its texts name.
@Suite struct AgentConnectRulesTests {
    private let linear = IntegrationCatalogEntry(
        id: "linear", name: "Linear", descriptionEn: "", descriptionRu: "", kind: .http, url: "https://mcp.linear.app/mcp",
        docsUrl: "", icon: "", auth: .oauth)
    private let fetch = IntegrationCatalogEntry(
        id: "fetch", name: "Fetch", descriptionEn: "", descriptionRu: "", kind: .stdio, command: "uvx",
        docsUrl: "", icon: "")

    @Test func aBrowserServiceStartsTheSignInWithADraftNamedLikeTheTemplate() {
        guard case .signIn(.draft(let draft)) = AgentConnectRules.start(entry: linear, existing: nil, supportsOAuth: true)
        else { Issue.record("expected a sign-in with a draft"); return }
        #expect(draft.name == "linear")
        #expect(draft.url == "https://mcp.linear.app/mcp")
        #expect(draft.kind == .http)
    }

    @Test func aBrowserServiceThatIsThereAlreadySignsInAgainInsteadOfBeingAddedTwice() {
        let row = Integration(id: "i1", name: "linear", kind: .http, url: "https://mcp.linear.app/mcp")
        let existing = AgentConnectRules.existing(for: linear, in: [row])
        #expect(existing?.id == "i1")
        guard case .signIn(.existing(let id)) = AgentConnectRules.start(
            entry: linear, existing: existing, supportsOAuth: true)
        else { Issue.record("expected a sign-in of the existing one"); return }
        #expect(id == "i1")
    }

    @Test func aServerWithoutBrowserSignInsAsksForAnUpdate() {
        guard case .needsUpdate = AgentConnectRules.start(entry: linear, existing: nil, supportsOAuth: false)
        else { Issue.record("expected needsUpdate"); return }
    }

    @Test func aServiceWithKeysOpensTheSheetOfTheCatalog() {
        guard case .sheet(let target) = AgentConnectRules.start(entry: fetch, existing: nil, supportsOAuth: false)
        else { Issue.record("expected the sheet"); return }
        #expect(target.id == "catalog-fetch")
    }

    @Test func aServiceWithKeysThatIsThereAlreadyOpensItsOwnSheet() {
        let row = Integration(id: "i2", name: "fetch", kind: .stdio, command: "uvx", enabled: false)
        guard case .sheet(let target) = AgentConnectRules.start(
            entry: fetch, existing: AgentConnectRules.existing(for: fetch, in: [row]), supportsOAuth: true)
        else { Issue.record("expected the sheet"); return }
        #expect(target.id == "edit-i2")
    }

    @Test func anIntegrationWithAnotherNameIsNotTheTemplate() {
        let other = Integration(id: "i3", name: "my-linear", kind: .http)
        #expect(AgentConnectRules.existing(for: linear, in: [other]) == nil)
    }

    @Test func theCardNamesTheServiceFromTheCatalogOrByItsId() {
        let known = ConnectRow(requestId: "r1", service: "linear", ts: 1)
        let unknown = ConnectRow(requestId: "r2", service: "mystery", ts: 2)
        #expect(AgentConnectRules.serviceName(of: known, catalog: [linear, fetch]) == "Linear")
        #expect(AgentConnectRules.serviceName(of: unknown, catalog: [linear, fetch]) == "mystery")
    }

    @Test func theHintIsAboutTheNewestRequestThatWaits() {
        let old = ConnectRow(requestId: "r1", service: "fetch", ts: 1)
        let new = ConnectRow(requestId: "r2", service: "linear", ts: 2)
        #expect(AgentConnectRules.waiting(in: [], catalog: [linear]) == nil)
        #expect(
            AgentConnectRules.waiting(in: [old, new], catalog: [linear, fetch])
                == ConnectWait(requestId: "r2", serviceName: "Linear"))
    }
}
