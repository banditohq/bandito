import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

private func template(_ id: String, _ category: String?, name: String? = nil) -> IntegrationCatalogEntry {
    IntegrationCatalogEntry(
        id: id, name: name ?? id, descriptionEn: "About \(id)", descriptionRu: "О \(id)", kind: .stdio,
        command: "run", docsUrl: "", icon: "", category: category)
}

private func connection(_ id: String, _ name: String, url: String? = nil, command: String? = "npx") -> Integration {
    Integration(id: id, name: name, kind: url == nil ? .stdio : .http, command: command, url: url)
}

private func entries(_ catalog: [IntegrationCatalogEntry], _ integrations: [Integration] = []) -> [MarketEntry] {
    MarketLogic.entries(catalog: catalog, integrations: integrations, languageCode: "en")
}

@Suite struct MarketSectionsTests {
    private let catalog = [
        template("a", "web"), template("b", "dev"), template("c", "data"), template("d", "dev"),
        template("e", "design"), template("f", "productivity"), template("g", "other"),
    ]

    @Test func connectedBlockIsFirstThenCategoriesInTheSidebarOrder() {
        let list = entries(catalog, [connection("i1", "d"), connection("own", "mine")])
        let sections = MarketSections.sections(list)
        #expect(
            sections.map(\.id)
                == ["connected", "category:dev", "category:productivity", "category:data", "category:web", "category:design", "category:other"])
        // The connected block has the connected catalog service and the owner's own one.
        #expect(sections[0].entries.map(\.id) == ["catalog:d", "own:own"])
    }

    @Test func aCategoryKeepsItsConnectedServicesAndMarksNothingElse() {
        let list = entries(catalog, [connection("i1", "d")])
        let dev = MarketSections.sections(list).first { $0.categoryName == "dev" }
        #expect(dev?.entries.map(\.id) == ["catalog:b", "catalog:d"])
        #expect(dev?.entries.map(\.isConnected) == [false, true])
    }

    @Test func noConnectedServicesNoConnectedBlock() {
        let sections = MarketSections.sections(entries(catalog))
        #expect(sections.first?.kind != .connected)
        #expect(!sections.contains { $0.kind == .connected })
    }

    @Test func anEmptyCategoryHasNoBlock() {
        let sections = MarketSections.sections(entries([template("a", "web"), template("b", "dev")]))
        #expect(sections.map(\.id) == ["category:dev", "category:web"])
    }

    @Test func aServiceWithoutACategoryGoesToOtherWhenTheCatalogHasCategories() {
        let sections = MarketSections.sections(entries([template("a", "dev"), template("b", nil)]))
        #expect(sections.map(\.id) == ["category:dev", "category:other"])
        #expect(sections[1].entries.map(\.id) == ["catalog:b"])
    }

    @Test func aDaemonWithoutCategoriesGivesOneCatalogBlock() {
        let old = (1...7).map { template("s\($0)", nil) }
        let sections = MarketSections.sections(entries(old, [connection("i", "s2")]))
        #expect(sections.map(\.id) == ["connected", "catalog"])
        #expect(sections[1].entries.count == 7)
        #expect(MarketCategory.present(in: old).isEmpty)
    }

    @Test func aSmallCatalogStillGivesSensibleBlocks() {
        let seven = [
            template("github", "dev"), template("linear", "productivity"), template("playwright", "web"),
            template("sentry", "dev"), template("notion", "productivity"), template("postgres", "data"),
            template("fetch", "web"),
        ]
        let sections = MarketSections.sections(entries(seven, [connection("i", "github")]))
        #expect(sections.map(\.id) == ["connected", "category:dev", "category:productivity", "category:data", "category:web"])
        #expect(sections.dropFirst().map(\.entries.count) == [2, 2, 1, 2])
    }

    @Test func unknownCategoriesFollowTheKnownOnesAlphabetically() {
        let sections = MarketSections.sections(entries([template("a", "zeta"), template("b", "dev"), template("c", "beta")]))
        #expect(sections.map(\.id) == ["category:dev", "category:beta", "category:zeta"])
    }

    @Test func noCatalogAndNoIntegrationsHasNoBlocks() {
        #expect(MarketSections.sections([]).isEmpty)
    }

    @Test func onlyOwnIntegrationsGiveTheConnectedBlockAlone() {
        let sections = MarketSections.sections(entries([], [connection("x", "mine")]))
        #expect(sections.map(\.id) == ["connected"])
    }

    @Test func sidebarCategoriesAgreeWithTheBlocks() {
        let cat = [template("a", "web"), template("b", "zeta"), template("c", "dev"), template("d", nil), template("e", "dev")]
        #expect(MarketCategory.present(in: cat) == ["dev", "web", "other", "zeta"])
        let blocks = MarketSections.sections(entries(cat)).compactMap(\.categoryName)
        #expect(blocks == MarketCategory.present(in: cat))
    }

    // MARK: content

    @Test func allWithNoSearchIsBlocks() {
        let list = entries(catalog)
        #expect(MarketSections.content(list, filter: .all, query: "  ") == .sections(MarketSections.sections(list)))
    }

    @Test func aSearchIsOneFlatListWithoutBlocks() {
        let list = entries(catalog, [connection("i1", "d")])
        guard case .flat(let found, let empty) = MarketSections.content(list, filter: .all, query: "about b") else {
            Issue.record("expected a flat list")
            return
        }
        #expect(found.map(\.id) == ["catalog:b"])
        #expect(empty == nil)
        // A connected service is found like any other.
        guard case .flat(let connected, _) = MarketSections.content(list, filter: .all, query: "About d") else { return }
        #expect(connected.map(\.isConnected) == [true])
    }

    @Test func aSearchWithNoMatchSaysSo() {
        let list = entries(catalog)
        #expect(MarketSections.content(list, filter: .all, query: "zzz") == .flat([], .noResults))
    }

    @Test func theConnectedFilterIsFlatAndSaysWhenNothingIsConnected() {
        let list = entries(catalog, [connection("i1", "d")])
        guard case .flat(let items, let empty) = MarketSections.content(list, filter: .connected, query: "") else {
            Issue.record("expected a flat list")
            return
        }
        #expect(items.map(\.id) == ["catalog:d"])
        #expect(empty == nil)
        #expect(MarketSections.content(entries(catalog), filter: .connected, query: "") == .flat([], .nothingConnected))
    }

    // MARK: tones

    @Test func everyKnownBlockHasItsOwnToneAndOthersAreStable() {
        let tones = ["dev", "productivity", "data", "web", "design", "other"].map { MarketTone.of(category: $0) }
        #expect(tones == [.sky, .peach, .lilac, .rose, .cream, .neutral])
        #expect(MarketTone.of(category: "zeta") == MarketTone.of(category: "zeta"))
        #expect(MarketTone.of(MarketSection(kind: .connected, entries: [])) == .connected)
        #expect(MarketTone.of(MarketSection(kind: .catalog, entries: [])) == .neutral)
    }
}

@Suite struct MarketGridLayoutTests {
    @Test func columnsFollowTheWidthBetweenTwoAndFour() {
        #expect(MarketGridLayout.columns(contentWidth: 0) == 2)
        #expect(MarketGridLayout.columns(contentWidth: .nan) == 2)
        #expect(MarketGridLayout.columns(contentWidth: 300) == 2)
        #expect(MarketGridLayout.columns(contentWidth: 477) == 2)
        #expect(MarketGridLayout.columns(contentWidth: 723) == 2)
        #expect(MarketGridLayout.columns(contentWidth: 724) == 3)
        #expect(MarketGridLayout.columns(contentWidth: 969) == 3)
        #expect(MarketGridLayout.columns(contentWidth: 970) == 4)
        #expect(MarketGridLayout.columns(contentWidth: 3000) == 4)
    }

    @Test func theScrollWidthLosesThePageMargins() {
        // A window with about 1000 pt of content: three roomy columns; a wider one: four.
        #expect(MarketGridLayout.columns(scrollWidth: 1000) == 3)
        #expect(MarketGridLayout.columns(scrollWidth: 1030) == 4)
        #expect(MarketGridLayout.columns(scrollWidth: 500) == 2)
    }

    @Test func cardsShareTheWidthAndFillItExactly() {
        for columns in 2...4 {
            let width: CGFloat = 940
            let card = MarketGridLayout.cardWidth(contentWidth: width, columns: columns)
            let total = card * CGFloat(columns) + MarketGridLayout.gap * CGFloat(columns - 1)
            #expect(abs(total - width) < 0.001)
        }
        #expect(MarketGridLayout.cardWidth(contentWidth: 940, columns: 0) == 0)
    }

    @Test func itemsAreCutIntoRows() {
        #expect(MarketGridLayout.rows([1, 2, 3, 4, 5], columns: 2) == [[1, 2], [3, 4], [5]])
        #expect(MarketGridLayout.rows([1, 2, 3], columns: 4) == [[1, 2, 3]])
        #expect(MarketGridLayout.rows([Int](), columns: 3).isEmpty)
        #expect(MarketGridLayout.rows([1, 2], columns: 0) == [[1], [2]])
        #expect(MarketGridLayout.rowCount(items: 5, columns: 2) == 3)
        #expect(MarketGridLayout.rowCount(items: 0, columns: 2) == 0)
        #expect(MarketGridLayout.rowCount(items: 4, columns: 4) == 1)
    }
}

@Suite struct MarketSectionMetricsTests {
    private typealias Metrics = MarketSectionMetrics

    @Test func aBlockIsItsHeaderItsRowsAndAGap() {
        let rows = CGFloat(MarketGridLayout.rowCount(items: 5, columns: 2))
        #expect(Metrics.height(cards: 5, columns: 2) == Metrics.headerHeight + rows * (Metrics.cardHeight + Metrics.rowGap) + Metrics.sectionGap)
        #expect(Metrics.height(cards: 5, columns: 4) < Metrics.height(cards: 5, columns: 2))
    }

    @Test func theLastBlockCanReachTheTop() {
        let last = Metrics.height(cards: 3, columns: 2)
        #expect(Metrics.bottomPadding(viewport: 700, last: last) == 700 - last)
        #expect(Metrics.bottomPadding(viewport: 100, last: 900) == 24)
    }
}

@MainActor
@Suite struct MarketSectionTrackerTests {
    private func tracker(_ ids: [String] = ["a", "b", "c"]) -> MarketSectionTracker {
        let tracker = MarketSectionTracker()
        tracker.configure(ids: ids)
        return tracker
    }

    @Test func nothingIsActiveBeforeAnAnchorPasses() {
        let t = tracker()
        #expect(t.active == nil)
        #expect(!t.report(index: 0, minY: 300))
        #expect(t.active == nil)
    }

    @Test func theLastAnchorThatHasPassedIsActive() {
        let t = tracker()
        #expect(t.report(index: 0, minY: 0))
        #expect(t.active == 0)
        #expect(t.report(index: 1, minY: 20))
        #expect(t.active == 1)
        // The next header reaches the bottom of the pinned one: it takes over there, not before.
        #expect(!t.report(index: 2, minY: Int(MarketSectionTracker.threshold) + 1))
        #expect(t.report(index: 2, minY: Int(MarketSectionTracker.threshold)))
        #expect(t.active == 2)
    }

    @Test func scrollingBackUpGivesTheBlockBack() {
        let t = tracker()
        _ = t.report(index: 0, minY: -400)
        _ = t.report(index: 1, minY: 0)
        #expect(t.active == 1)
        #expect(t.report(index: 1, minY: 120))
        #expect(t.active == 0)
    }

    @Test func aMoveThatChangesNothingIsNotReported() {
        let t = tracker()
        _ = t.report(index: 0, minY: -10)
        #expect(!t.report(index: 0, minY: -20))
        #expect(!t.report(index: 1, minY: 500))
    }

    @Test func aChangeInsideAJumpIsNotReported() {
        let t = tracker()
        t.quietUntil = 100
        #expect(!t.report(index: 0, minY: 0, now: 50))
        #expect(t.active == 0)
        // The state is kept: the same block is not reported again later.
        #expect(!t.report(index: 0, minY: -5, now: 150))
    }

    @Test func aJumpSetsTheFlagsOfAnchorsThatWereNeverBuilt() {
        let t = tracker(["a", "b", "c", "d"])
        _ = t.report(index: 3, minY: 0)
        #expect(t.active == 3)
        t.jump(to: 1)
        #expect(t.active == 1)
        t.jump(to: nil)
        #expect(t.active == nil)
    }

    @Test func positionsAreRememberedAndForgottenOnReset() {
        let t = tracker()
        _ = t.report(index: 1, minY: 12)
        #expect(t.minY(of: "b") == 12)
        #expect(t.minY(of: "c") == nil)
        t.reportTop(3)
        #expect(t.topY == 3)
        t.reset()
        #expect(t.minY(of: "b") == nil)
        #expect(t.topY == nil)
        #expect(t.active == nil)
    }

    @Test func aNewListOfBlocksStartsOver() {
        let t = tracker()
        _ = t.report(index: 2, minY: 0)
        t.configure(ids: ["a", "b", "c"])
        #expect(t.active == 2)
        t.configure(ids: ["a", "b"])
        #expect(t.active == nil)
        #expect(!t.report(index: 5, minY: 0))
    }
}

@Suite struct MarketSidebarLogicTests {
    @Test func onServicesAllAndCategoriesScrollAndConnectedFilters() {
        #expect(MarketSidebarLogic.action(for: .all, tab: .services) == .scroll(.top))
        #expect(MarketSidebarLogic.action(for: .category("dev"), tab: .services) == .scroll(.category("dev")))
        #expect(MarketSidebarLogic.action(for: .connected, tab: .services) == .filter(.connected))
    }

    @Test func botsAndSkillsFilterAsBefore() {
        #expect(MarketSidebarLogic.action(for: .category("ops"), tab: .bots) == .filter(.category("ops")))
        #expect(MarketSidebarLogic.action(for: .all, tab: .skills) == .filter(.all))
        #expect(MarketSidebarLogic.action(for: .installed, tab: .skills) == .filter(.installed))
    }

    @Test func underAllTheBlockInViewIsLit() {
        #expect(MarketSidebarLogic.highlighted(tab: .services, filter: .all, section: nil) == .all)
        #expect(MarketSidebarLogic.highlighted(tab: .services, filter: .all, section: "web") == .category("web"))
        // The Connected filter and the other pages keep their own row.
        #expect(MarketSidebarLogic.highlighted(tab: .services, filter: .connected, section: "web") == .connected)
        #expect(MarketSidebarLogic.highlighted(tab: .bots, filter: .category("ops"), section: "web") == .category("ops"))
    }

    @Test func aTargetLandsOnTheTopOrOnItsBlock() {
        let sections = MarketSections.sections(entries([template("a", "dev"), template("b", "web")]))
        #expect(MarketSidebarLogic.landing(of: .top, sections: sections) == .top)
        #expect(MarketSidebarLogic.landing(of: .category("web"), sections: sections) == .section(1))
        // A category with no block (empty, or gone) has no place.
        #expect(MarketSidebarLogic.landing(of: .category("design"), sections: sections) == nil)
        #expect(MarketLanding.section(1).index == 1)
        #expect(MarketLanding.top.index == nil)
    }

    @Test func aRequestExpires() {
        let request = MarketScrollRequest(id: 1, target: .top, created: 100)
        #expect(request.isFresh(at: 105))
        #expect(!request.isFresh(at: 109))
    }
}
