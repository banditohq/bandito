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
        #expect(all.grid.map(\.id) == ["catalog:github", "catalog:playwright"])

        let connected = MarketLogic.page(entries, filter: .connected, query: "")
        #expect(connected.connected.isEmpty)
        #expect(connected.grid.map(\.id) == ["catalog:linear", "own:tool-1"])

        let searched = MarketLogic.page(entries, filter: .all, query: "linear")
        #expect(searched.connected.map(\.id) == ["catalog:linear"])
        #expect(searched.grid.isEmpty)
    }

    @Test func connectedServicesAreNotRepeatedInTheGridUnderAll() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [connection("i1", "github")], languageCode: "en")
        let all = MarketLogic.page(entries, filter: .all, query: "")
        #expect(all.connected.map(\.id) == ["catalog:github"])
        #expect(!all.grid.contains { $0.id == "catalog:github" })
        #expect(all.grid.map(\.id) == ["catalog:linear", "catalog:playwright"])
    }

    @Test func emptyStateNamesTheReason() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [connection("i1", "linear")], languageCode: "en")

        let noMatch = MarketLogic.page(entries, filter: .all, query: "zzz")
        #expect(MarketLogic.emptyState(noMatch, filter: .all, query: "zzz") == .noResults)

        let nothingConnected = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "en")
        let none = MarketLogic.page(nothingConnected, filter: .connected, query: "")
        #expect(MarketLogic.emptyState(none, filter: .connected, query: "") == .nothingConnected)

        // Under All with every service connected the row shows them: no text.
        let allConnected = MarketLogic.entries(
            catalog: catalog,
            integrations: [connection("github", "github"), connection("linear", "linear"), connection("playwright", "playwright")],
            languageCode: "en")
        let full = MarketLogic.page(allConnected, filter: .all, query: "")
        #expect(MarketLogic.emptyState(full, filter: .all, query: "") == nil)

        let shown = MarketLogic.page(entries, filter: .all, query: "")
        #expect(MarketLogic.emptyState(shown, filter: .all, query: "") == nil)
    }

    private func categorized(_ id: String, _ category: String?, kind: IntegrationKind = .stdio, keys: [IntegrationHeaderKey] = [], url: String? = nil, args: [String] = []) -> IntegrationCatalogEntry {
        IntegrationCatalogEntry(
            id: id, name: id, descriptionEn: id, descriptionRu: id, kind: kind, command: kind == .stdio ? "run" : nil,
            args: args, url: url, headersKeys: kind == .http ? keys : [], envKeys: kind == .stdio ? keys : [], docsUrl: "", icon: "",
            category: category)
    }

    @Test func aCategoryListsItsServicesConnectedOrNot() {
        let cat = [categorized("a", "dev"), categorized("b", "web"), categorized("c", "dev")]
        let entries = MarketLogic.entries(catalog: cat, integrations: [connection("i1", "c"), connection("own", "mine")], languageCode: "en")
        let page = MarketLogic.page(entries, filter: .category("dev"), query: "")
        #expect(page.connected.isEmpty)
        #expect(page.grid.map(\.id) == ["catalog:a", "catalog:c"])
        #expect(MarketLogic.page(entries, filter: .category("web"), query: "zzz").grid.isEmpty)
        let none = MarketLogic.page(entries, filter: .category("design"), query: "")
        #expect(MarketLogic.emptyState(none, filter: .category("design"), query: "") == nil)
    }

    @Test func sidebarCategoriesFollowTheFixedOrderThenUnknownOnes() {
        let cat = [categorized("a", "web"), categorized("b", "zeta"), categorized("c", "dev"), categorized("d", nil), categorized("e", "dev")]
        #expect(MarketCategory.present(in: cat) == ["dev", "web", "zeta"])
        #expect(MarketFilter.rows(categories: ["dev"]).map(\.id) == ["all", "connected", "category:dev"])
        #expect(MarketCategory.present(in: []).isEmpty)
    }

    @Test func theOpenPageIsFoundByIDAndGoneWhenTheEntryIs() {
        let entries = MarketLogic.entries(catalog: catalog, integrations: [connection("o1", "my-tool")], languageCode: "en")
        #expect(MarketLogic.entry(withID: "catalog:linear", in: entries)?.name == "Linear")
        #expect(MarketLogic.entry(withID: "own:o1", in: entries)?.name == "my-tool")
        #expect(MarketLogic.entry(withID: nil, in: entries) == nil)
        let after = MarketLogic.entries(catalog: catalog, integrations: [], languageCode: "en")
        #expect(MarketLogic.entry(withID: "own:o1", in: after) == nil)
    }

    @Test func connectStepsComeFromTheFields() {
        let key = IntegrationHeaderKey(key: "K", labelEn: "k", labelRu: "к", secret: true, valueTemplate: "{secret}")
        #expect(MarketLogic.steps(for: categorized("a", nil)) == [.connect])
        #expect(MarketLogic.steps(for: categorized("a", nil, kind: .http, keys: [key], url: "https://x.test")) == [.getKey, .connect])
        #expect(MarketLogic.steps(for: categorized("a", nil, kind: .http, keys: [key])) == [.getKey, .fillAddress, .connect])
        #expect(MarketLogic.steps(for: categorized("a", nil, keys: [key], args: ["-y", "/path/to/x"])) == [.getKey, .fillPath, .connect])
    }

    @Test func tileColourIsTheBrandAccentOrAStablePaletteChoice() {
        let branded = IntegrationCatalogEntry(
            id: "a", name: "A", descriptionEn: "", descriptionRu: "", kind: .stdio, docsUrl: "", icon: "", accent: "#5E6AD2")
        let broken = IntegrationCatalogEntry(
            id: "b", name: "B", descriptionEn: "", descriptionRu: "", kind: .stdio, docsUrl: "", icon: "", accent: "nope")
        let entries = MarketLogic.entries(
            catalog: [branded, broken], integrations: [connection("o", "my-tool")], languageCode: "en")
        #expect(MarketTileStyle.accent(of: entries[0]) == 0x5E6AD2)
        #expect(MarketTileStyle.accent(of: entries[1]) == nil)
        #expect(MarketTileStyle.accent(of: entries[2]) == nil)
        let index = MarketTileStyle.paletteIndex(for: "my-tool")
        #expect(index == MarketTileStyle.paletteIndex(for: "My-Tool"))
        #expect((0..<AvatarColor.allCases.count).contains(index))
        #expect(MarketTileStyle.paletteIndex(for: "x", count: 0) == 0)
    }
}
