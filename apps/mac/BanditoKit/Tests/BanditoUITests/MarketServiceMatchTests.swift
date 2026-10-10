import BanditoKit
import Testing

@testable import BanditoUI

/// A web catalog template with an address and a category (the Notion one, say).
private func webTemplate(_ id: String, _ name: String, url: String?, category: String? = nil) -> IntegrationCatalogEntry {
    IntegrationCatalogEntry(
        id: id, name: name, descriptionEn: "", descriptionRu: "", kind: .http, url: url, docsUrl: "", icon: "",
        category: category)
}

private func webConnection(_ id: String, _ name: String, url: String?) -> Integration {
    Integration(id: id, name: name, kind: .http, url: url)
}

@Suite struct MarketServiceMatchTests {
    private let notion = webTemplate("notion", "Notion", url: "https://mcp.notion.com/mcp", category: "productivity")
    private let linear = webTemplate("linear", "Linear", url: "https://mcp.linear.app/mcp")
    private let noLogo = webTemplate("no-such-logo", "Plain", url: nil)

    private var catalog: [IntegrationCatalogEntry] { [notion, linear, noLogo] }

    @Test func nameEqualToTemplateIDMatches() {
        let match = MarketLogic.template(for: webConnection("i1", "notion", url: nil), in: catalog)
        #expect(match?.id == "notion")
        #expect(match?.name == "Notion")
    }

    @Test func addressMatchesWithOrWithoutTrailingSlash() {
        let withSlash = webConnection("i1", "my-notion", url: "https://mcp.notion.com/mcp/")
        let without = webConnection("i2", "my-notion", url: "https://mcp.notion.com/mcp")
        #expect(MarketLogic.template(for: withSlash, in: catalog)?.id == "notion")
        #expect(MarketLogic.template(for: without, in: catalog)?.id == "notion")
    }

    @Test func schemeAndHostIgnoreCaseButThePathDoesNot() {
        let host = webConnection("i1", "my-notion", url: "HTTPS://MCP.Notion.COM/mcp")
        #expect(MarketLogic.template(for: host, in: catalog)?.id == "notion")
        let path = webConnection("i2", "my-notion", url: "https://mcp.notion.com/MCP")
        #expect(MarketLogic.template(for: path, in: catalog) == nil)
    }

    @Test func normalizedURLLowersSchemeAndHostAndDropsTheTrailingSlash() {
        #expect(MarketLogic.normalizedURL("HTTPS://Mcp.Notion.com/mcp/") == "https://mcp.notion.com/mcp")
        #expect(MarketLogic.normalizedURL("  https://mcp.notion.com/mcp  ") == "https://mcp.notion.com/mcp")
        #expect(MarketLogic.normalizedURL("https://x.test/a//") == "https://x.test/a")
        #expect(MarketLogic.normalizedURL(nil) == nil)
        #expect(MarketLogic.normalizedURL("  /  ") == nil)
    }

    @Test func noMatchIsNilAndTheEntryKeepsTheDaemonsName() {
        let own = webConnection("i1", "my-server", url: "https://example.com/mcp")
        #expect(MarketLogic.template(for: own, in: catalog) == nil)
        let entries = MarketLogic.entries(catalog: catalog, integrations: [own], languageCode: "en")
        #expect(entries.last?.name == "my-server")
        #expect(entries.last?.isOwn == true)
        let stdio = Integration(id: "i2", name: "tool", kind: .stdio, command: "run")
        #expect(MarketLogic.template(for: stdio, in: [noLogo]) == nil)
    }

    @Test func nameWinsOverAddress() {
        let byName = webConnection("i1", "linear", url: "https://mcp.notion.com/mcp")
        #expect(MarketLogic.template(for: byName, in: catalog)?.id == "linear")
    }

    @Test func twoIntegrationsWithOneAddressMainOneGetsTheNameOtherKeepsItsOwn() {
        let main = webConnection("i1", "notion-a", url: "https://mcp.notion.com/mcp")
        let second = webConnection("i2", "notion-b", url: "https://mcp.notion.com/mcp/")
        let entries = MarketLogic.entries(catalog: catalog, integrations: [main, second], languageCode: "en")
        // The template entry takes the first one; the second is an own entry under its own name, with the logo.
        #expect(entries.map(\.id) == ["catalog:notion", "catalog:linear", "catalog:no-such-logo", "own:i2"])
        #expect(entries.first { $0.id == "catalog:notion" }?.integration?.id == "i1")
        #expect(entries.first { $0.id == "catalog:notion" }?.name == "Notion")
        let other = entries.first { $0.id == "own:i2" }
        #expect(other?.name == "notion-b")
        #expect(other?.template?.id == "notion")
        #expect(other?.isConnected == true)
        #expect(other?.category == nil)
        #expect(entries.filter { $0.isConnected }.count == 2)
    }

    @Test func aSecondConnectionIsNotListedInItsCategory() {
        let second = webConnection("i2", "notion-b", url: "https://mcp.notion.com/mcp")
        let main = webConnection("i1", "notion-a", url: "https://mcp.notion.com/mcp")
        let entries = MarketLogic.entries(catalog: catalog, integrations: [main, second], languageCode: "en")
        let inCategory = MarketLogic.visible(entries, filter: .category("productivity"), query: "")
        #expect(inCategory.map(\.id) == ["catalog:notion"])
        #expect(MarketLogic.visible(entries, filter: .connected, query: "").map(\.id) == ["catalog:notion", "own:i2"])
    }

    @Test func integrationNamedAfterATemplateIsTheTemplatesEntryNotADuplicate() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [webConnection("i1", "notion", url: nil)], languageCode: "en")
        #expect(entries.map(\.id) == ["catalog:notion", "catalog:linear", "catalog:no-such-logo"])
        #expect(entries[0].isConnected)
    }

    @Test func urlMatchedIntegrationIsConnectedToTheTemplate() {
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [webConnection("i1", "my-notion", url: "https://mcp.notion.com/mcp/")],
            languageCode: "en")
        #expect(entries.map(\.id) == ["catalog:notion", "catalog:linear", "catalog:no-such-logo"])
        #expect(entries[0].integration?.name == "my-notion")
        #expect(entries[0].name == "Notion")
    }

    @Test func templateWithoutLogoStillMatches() {
        // A template whose id has no SVG in Resources/ServiceLogos has no logo; the tile falls back to its symbol.
        #expect(ServiceLogo.image(for: "no-such-logo") == nil)
        let entries = MarketLogic.entries(
            catalog: catalog, integrations: [webConnection("i1", "no-such-logo", url: nil)], languageCode: "en")
        #expect(entries[2].name == "Plain")
        #expect(entries[2].isConnected)
    }
}
