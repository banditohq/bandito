import BanditoKit
import Testing

@testable import BanditoUI

/// A catalog template with a fixed English and Russian description (the Russian one ends with " (ru)").
private func template(_ id: String, _ name: String, _ english: String) -> IntegrationCatalogEntry {
    IntegrationCatalogEntry(
        id: id, name: name, descriptionEn: english, descriptionRu: english + " (ru)", kind: .stdio,
        command: "run", docsUrl: "", icon: "")
}

private func connection(
    _ id: String, _ name: String, kind: IntegrationKind = .stdio, command: String? = "npx", url: String? = nil,
    args: [String] = []
) -> Integration {
    Integration(id: id, name: name, kind: kind, command: command, args: args, url: url)
}

@Suite struct MarketLogicTests {
    private let catalog = [
        template("github", "GitHub", "Repositories and pull requests."),
        template("linear", "Linear", "Issues and projects."),
        template("playwright", "Playwright", "Drive a browser."),
    ]

    @Test func catalogComesFirstAndAConnectedTemplateIsOneEntry() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [connection("i1", "linear")], languageCode: "en")
        #expect(entries.map(\.id) == ["catalog:github", "catalog:linear", "catalog:playwright"])
        #expect(entries.map(\.isConnected) == [false, true, false])
    }

    @Test func ownIntegrationsAreAppendedWithTheirAddress() {
        let program = connection("tool-1", "my-tool", command: "/usr/local/bin/mytool", args: ["--stdio"])
        let web = connection("tool-2", "my-web", kind: .http, command: nil, url: "https://example.com/mcp")
        let entries = MarketLogic.entries(catalog: catalog, integrations: [program, web], languageCode: "en")
        #expect(entries.count == 5)
        #expect(entries[3].id == "own:tool-1")
        #expect(entries[3].template == nil)
        #expect(entries[3].description == "/usr/local/bin/mytool --stdio")
        #expect(entries[4].description == "https://example.com/mcp")
    }

    @Test func descriptionFollowsTheLanguage() {
        let russian = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "ru-RU")
        let german = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "de")
        #expect(russian[0].description == "Repositories and pull requests. (ru)")
        #expect(german[0].description == "Repositories and pull requests.")
    }

    @Test func connectedFilterKeepsOnlyConnectedEntries() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [connection("i1", "linear"), connection("tool-1", "my-tool")],
            languageCode: "en")
        #expect(MarketLogic.visible(entries, filter: .connected, query: "").map(\.id) == ["catalog:linear", "own:tool-1"])
        #expect(MarketLogic.visible(entries, filter: .all, query: "").count == 4)
    }

    @Test func searchIgnoresCaseAndOuterSpaces() {
        let entries = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "en")
        #expect(MarketLogic.visible(entries, filter: .all, query: "  LINEAR ").map(\.id) == ["catalog:linear"])
    }

    @Test func searchReadsTheDescriptionToo() {
        let entries = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "en")
        #expect(MarketLogic.visible(entries, filter: .all, query: "browser").map(\.id) == ["catalog:playwright"])
    }

    @Test func searchWithNoMatchIsEmptyAndABlankSearchKeepsEverything() {
        let entries = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "en")
        #expect(MarketLogic.visible(entries, filter: .all, query: "zzz").isEmpty)
        #expect(MarketLogic.visible(entries, filter: .all, query: "   ").count == 3)
    }

    @Test func connectedRowShowsOnlyUnderAllAndOnlyMatches() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [connection("i1", "linear"), connection("tool-1", "my-tool")],
            languageCode: "en")

        let all = MarketLogic.page(entries, filter: .all, query: "")
        #expect(all.connected.map(\.id) == ["catalog:linear", "own:tool-1"])
        #expect(all.grid.count == 4)

        let connected = MarketLogic.page(entries, filter: .connected, query: "")
        #expect(connected.connected.isEmpty)
        #expect(connected.grid.map(\.id) == ["catalog:linear", "own:tool-1"])

        let searched = MarketLogic.page(entries, filter: .all, query: "linear")
        #expect(searched.connected.map(\.id) == ["catalog:linear"])
        #expect(searched.grid.map(\.id) == ["catalog:linear"])
    }
}
