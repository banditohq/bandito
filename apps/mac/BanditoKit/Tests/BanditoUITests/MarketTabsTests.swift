import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The three pages of the Marketplace: which ones a server offers, the page that is remembered, and the sidebar rows.
@MainActor
@Suite struct MarketTabsTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "MarketTabsTests.\(UUID().uuidString)"))
    }

    @Test func aServerShowsOnlyThePagesItsFeaturesAllow() {
        #expect(MarketTab.available { _ in false } == [.services])
        #expect(MarketTab.available { $0 == "agent_templates" } == [.services, .bots])
        #expect(MarketTab.available { $0 == "skills" } == [.services, .skills])
        #expect(MarketTab.available { _ in true } == [.services, .bots, .skills])
    }

    @Test func aPageTheServerLacksFallsBackToServices() {
        let tabs = MarketTab.available { $0 == "agent_templates" }
        #expect(MarketTab.effective(.bots, available: tabs) == .bots)
        #expect(MarketTab.effective(.skills, available: tabs) == .services)
        #expect(MarketTab.effective(.services, available: tabs) == .services)
    }

    @Test func theLastPageIsRememberedInTheGivenDefaults() throws {
        let store = try defaults()
        #expect(MarketTabStore.load(defaults: store) == .services)
        MarketTabStore.save(.skills, defaults: store)
        #expect(MarketTabStore.load(defaults: store) == .skills)
        store.set("nonsense", forKey: MarketTabStore.key)
        #expect(MarketTabStore.load(defaults: store) == .services)
    }

    @Test func theRouterStartsOnTheRememberedPage() throws {
        let store = try defaults()
        MarketTabStore.save(.bots, defaults: store)
        #expect(Router(defaults: store).marketTab == .bots)
        #expect(Router(defaults: try defaults()).marketTab == .services)
    }

    @Test func eachPageHasItsOwnSidebarRows() {
        #expect(MarketTab.services.filterRows(categories: ["dev"]) == [.all, .connected, .category("dev")])
        #expect(MarketTab.bots.filterRows(categories: ["ops", "dev"]) == [.all, .myBots, .category("ops"), .category("dev")])
        #expect(MarketTab.skills.filterRows(categories: []) == [.all, .installed])
        // The old helper of the services page keeps its rows.
        #expect(MarketFilter.rows(categories: ["web"]) == [.all, .connected, .category("web")])
    }

    @Test func theNewCategoriesHaveWordsAndAnUnknownOneIsCapitalised() {
        for name in ["ops", "research", "writing", "business", "personal", "dev", "data", "design", "productivity"] {
            #expect(MarketCategory.title(name) != name)
        }
        #expect(MarketCategory.title("hobby") == "Hobby")
    }
}
