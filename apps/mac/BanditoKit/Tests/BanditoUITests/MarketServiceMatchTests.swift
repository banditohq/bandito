import BanditoKit
import Testing

@testable import BanditoUI

/// A web catalog template with an address (the Notion one, say).
private func webTemplate(_ id: String, _ name: String, url: String?) -> IntegrationCatalogEntry {
    IntegrationCatalogEntry(
        id: id, name: name, descriptionEn: "", descriptionRu: "", kind: .http, url: url, docsUrl: "", icon: "")
}

private func webConnection(_ id: String, _ name: String, url: String?) -> Integration {
    Integration(id: id, name: name, kind: .http, url: url)
}

@Suite struct MarketServiceMatchTests {
    private let notion = webTemplate("notion", "Notion", url: "https://mcp.notion.com/mcp")
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

    @Test func noMatchIsNilAndTheDisplayNameIsTheDaemonsName() {
        let own = webConnection("i1", "my-server", url: "https://example.com/mcp")
        #expect(MarketLogic.template(for: own, in: catalog) == nil)
        #expect(MarketLogic.displayName(of: own, in: catalog) == "my-server")
        #expect(MarketLogic.displayName(of: webConnection("i2", "notion", url: nil), in: catalog) == "Notion")
    }

    @Test func nameWinsOverAddress() {
        let byName = webConnection("i1", "linear", url: "https://mcp.notion.com/mcp")
        #expect(MarketLogic.template(for: byName, in: catalog)?.id == "linear")
    }

    @Test func emptyOrMissingAddressMatchesNothing() {
        #expect(MarketLogic.normalizedURL(nil) == nil)
        #expect(MarketLogic.normalizedURL("  /  ") == nil)
        let stdio = Integration(id: "i1", name: "tool", kind: .stdio, command: "run")
        #expect(MarketLogic.template(for: stdio, in: [noLogo]) == nil)
    }

    @Test func twoIntegrationsWithOneAddressBothGetTheTemplateName() {
        let first = webConnection("i1", "notion-a", url: "https://mcp.notion.com/mcp")
        let second = webConnection("i2", "notion-b", url: "https://mcp.notion.com/mcp/")
        let entries = MarketLogic.entries(catalog: catalog, integrations: [first, second], languageCode: "en")
        // The template entry takes the first one; the second is an own entry that carries the same template.
        #expect(entries.first { $0.id == "catalog:notion" }?.integration?.id == "i1")
        let other = entries.first { $0.id == "own:i2" }
        #expect(other?.name == "Notion")
        #expect(other?.template?.id == "notion")
        #expect(other?.isConnected == true)
        #expect(entries.filter { $0.isConnected }.count == 2)
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
