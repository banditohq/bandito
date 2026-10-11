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

@Suite struct MarketShelvesTests {
    private let catalog = [
        template("a", "web"), template("b", "dev"), template("c", "data"), template("d", "dev"),
        template("e", "design"), template("f", "productivity"), template("g", "other"),
    ]

    @Test func connectedShelfIsFirstThenTheCategoriesInTheSidebarOrder() {
        let list = entries(catalog, [connection("i1", "d"), connection("own", "mine")])
        let shelves = MarketSections.shelves(list)
        #expect(
            shelves.map(\.id)
                == ["connected", "category:dev", "category:productivity", "category:data", "category:web", "category:design", "category:other"])
        // The connected shelf has the connected catalog service and the owner's own one.
        #expect(shelves[0].entries.map(\.id) == ["catalog:d", "own:own"])
        #expect(shelves[0].count == 2)
    }

    @Test func theSuggestionsComeRightAfterTheConnectedShelf() {
        let list = entries(catalog, [connection("i1", "d")])
        let ids = MarketSections.shelves(list, recommended: 3).map(\.id)
        #expect(ids.prefix(3) == ["connected", "recommended", "category:dev"])
        let recommended = MarketSections.shelves(list, recommended: 3)[1]
        #expect(recommended.kind == .recommended)
        #expect(recommended.count == 3)
        #expect(recommended.entries.isEmpty)
        #expect(recommended.destination == nil)
    }

    @Test func withNothingConnectedTheSuggestionsAreFirst() {
        let ids = MarketSections.shelves(entries(catalog), recommended: 2).map(\.id)
        #expect(ids.first == "recommended")
        #expect(!ids.contains("connected"))
        #expect(MarketSections.shelves(entries(catalog), recommended: 0).first?.kind != .recommended)
    }

    @Test func aCategoryKeepsItsConnectedServicesAndCountsAllOfThem() {
        let list = entries(catalog, [connection("i1", "d")])
        let dev = MarketSections.shelves(list).first { $0.categoryName == "dev" }
        #expect(dev?.entries.map(\.id) == ["catalog:b", "catalog:d"])
        #expect(dev?.entries.map(\.isConnected) == [false, true])
        #expect(dev?.count == 2)
    }

    @Test func noConnectedServicesNoConnectedShelf() {
        #expect(!MarketSections.shelves(entries(catalog)).contains { $0.kind == .connected })
    }

    @Test func anEmptyCategoryHasNoShelf() {
        let shelves = MarketSections.shelves(entries([template("a", "web"), template("b", "dev")]))
        #expect(shelves.map(\.id) == ["category:dev", "category:web"])
        #expect(shelves.allSatisfy { $0.count > 0 })
    }

    @Test func aServiceWithoutACategoryGoesToOtherWhenTheCatalogHasCategories() {
        let shelves = MarketSections.shelves(entries([template("a", "dev"), template("b", nil)]))
        #expect(shelves.map(\.id) == ["category:dev", "category:other"])
        #expect(shelves[1].entries.map(\.id) == ["catalog:b"])
    }

    @Test func aDaemonWithoutCategoriesGivesOneCatalogBlockThatOpensNothing() {
        let old = (1...7).map { template("s\($0)", nil) }
        let shelves = MarketSections.shelves(entries(old, [connection("i", "s2")]))
        #expect(shelves.map(\.id) == ["connected", "catalog"])
        #expect(shelves[1].entries.count == 7)
        #expect(shelves[1].destination == nil)
        #expect(MarketCategory.present(in: old).isEmpty)
    }

    @Test func aSmallCatalogStillGivesSensibleShelves() {
        let seven = [
            template("github", "dev"), template("linear", "productivity"), template("playwright", "web"),
            template("sentry", "dev"), template("notion", "productivity"), template("postgres", "data"),
            template("fetch", "web"),
        ]
        let shelves = MarketSections.shelves(entries(seven, [connection("i", "github")]))
        #expect(shelves.map(\.id) == ["connected", "category:dev", "category:productivity", "category:data", "category:web"])
        #expect(shelves.dropFirst().map(\.count) == [2, 2, 1, 2])
    }

    @Test func unknownCategoriesFollowTheKnownOnesAlphabetically() {
        let shelves = MarketSections.shelves(entries([template("a", "zeta"), template("b", "dev"), template("c", "beta")]))
        #expect(shelves.map(\.id) == ["category:dev", "category:beta", "category:zeta"])
    }

    @Test func noCatalogAndNoIntegrationsHasNoShelves() {
        #expect(MarketSections.shelves([]).isEmpty)
    }

    @Test func onlyOwnIntegrationsGiveTheConnectedShelfAlone() {
        #expect(MarketSections.shelves(entries([], [connection("x", "mine")])).map(\.id) == ["connected"])
    }

    @Test func sidebarCategoriesAgreeWithTheShelves() {
        let cat = [template("a", "web"), template("b", "zeta"), template("c", "dev"), template("d", nil), template("e", "dev")]
        #expect(MarketCategory.present(in: cat) == ["dev", "web", "other", "zeta"])
        #expect(MarketSections.shelves(entries(cat)).compactMap(\.categoryName) == MarketCategory.present(in: cat))
    }

    @Test func eachShelfHasASymbolAndTheOnesWithAPageOpenIt() {
        let shelves = MarketSections.shelves(entries(catalog, [connection("i1", "d")]), recommended: 1)
        #expect(shelves.allSatisfy { !$0.symbol.isEmpty })
        #expect(shelves.first { $0.kind == .connected }?.destination == .connected)
        #expect(shelves.first { $0.categoryName == "web" }?.destination == .category("web"))
        #expect(MarketCategory.symbol("dev") != MarketCategory.symbol("web"))
        #expect(MarketCategory.symbol("zeta") == "tag")
    }

    // MARK: content

    @Test func allWithNoSearchIsTheShelves() {
        let list = entries(catalog)
        #expect(MarketSections.content(list, filter: .all, query: "  ") == .shelves(MarketSections.shelves(list)))
        #expect(
            MarketSections.content(list, filter: .all, query: "", recommended: 2)
                == .shelves(MarketSections.shelves(list, recommended: 2)))
    }

    @Test func aSearchUnderAllIsOneFlatListWithoutShelves() {
        let list = entries(catalog, [connection("i1", "d")])
        guard case .flat(let found, let empty) = MarketSections.content(list, filter: .all, query: "about b", recommended: 2) else {
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
        #expect(MarketSections.content(entries(catalog), filter: .all, query: "zzz") == .flat([], .noResults))
    }

    @Test func aCategoryIsItsOwnPageAndASearchNarrowsIt() {
        let list = entries(catalog, [connection("i1", "d")])
        #expect(
            MarketSections.content(list, filter: .category("dev"), query: "")
                == .page(.category("dev"), list.filter { $0.category == "dev" }, nil))
        guard case .page(let kind, let found, _) = MarketSections.content(list, filter: .category("dev"), query: "about d") else {
            Issue.record("expected a page")
            return
        }
        #expect(kind == .category("dev"))
        #expect(found.map(\.id) == ["catalog:d"])
        #expect(MarketSections.content(list, filter: .category("dev"), query: "zzz") == .page(.category("dev"), [], .noResults))
    }

    @Test func theConnectedPageSaysWhenNothingIsConnected() {
        let list = entries(catalog, [connection("i1", "d")])
        guard case .page(let kind, let items, let empty) = MarketSections.content(list, filter: .connected, query: "") else {
            Issue.record("expected a page")
            return
        }
        #expect(kind == .connected)
        #expect(items.map(\.id) == ["catalog:d"])
        #expect(empty == nil)
        #expect(MarketSections.content(entries(catalog), filter: .connected, query: "") == .page(.connected, [], .nothingConnected))
    }

    @Test func allOnAShelfOpensAPageWithTheSameCardsAndBackIsTheShelves() {
        let list = entries(catalog, [connection("i1", "d"), connection("own", "mine")])
        let shelves = MarketSections.shelves(list)
        for shelf in shelves {
            guard let destination = shelf.destination else { continue }
            let content = MarketSections.content(list, filter: destination, query: "")
            guard case .page(let kind, let items, _) = content else {
                Issue.record("\(shelf.id) did not open a page")
                continue
            }
            // The number in the shelf's header is the number of cards on its page.
            #expect(items == shelf.entries)
            #expect(items.count == shelf.count)
            // Back sets the filter to All: the shelves again.
            #expect(kind.filter == destination)
            #expect(MarketSections.content(list, filter: .all, query: "") == .shelves(shelves))
        }
    }

    // MARK: page mode

    @Test func theModeFollowsTheFilterAndTheSearch() {
        #expect(MarketPageMode.of(filter: .all, searching: false) == .shelves)
        #expect(MarketPageMode.of(filter: .all, searching: true) == .flat)
        #expect(MarketPageMode.of(filter: .category("dev"), searching: false) == .page)
        #expect(MarketPageMode.of(filter: .category("dev"), searching: true) == .page)
        #expect(MarketPageMode.of(filter: .connected, searching: false) == .page)
        #expect(MarketPageMode.of(filter: .bundles, searching: false) == .page)
        #expect(MarketPageMode.of(filter: .installed, searching: false) == .flat)
        #expect(MarketPageMode.of(filter: .myBots, searching: true) == .flat)
    }

    // MARK: shelves of bots and skills

    private struct Thing: Identifiable, Equatable {
        let id: String
        let category: String
    }

    @Test func thingsAreGroupedByCategoryInTheGivenOrderThenAlphabetically() {
        let things = [Thing(id: "1", category: "zeta"), Thing(id: "2", category: "dev"), Thing(id: "3", category: "ops"),
            Thing(id: "4", category: "dev"), Thing(id: "5", category: "beta")]
        let shelves = MarketCategoryShelf.group(things, category: \.category, order: ["dev", "ops"])
        #expect(shelves.map(\.category) == ["dev", "ops", "beta", "zeta"])
        #expect(shelves[0].items.map(\.id) == ["2", "4"])
        #expect(MarketCategoryShelf.group([Thing](), category: \.category, order: ["dev"]).isEmpty)
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

@Suite struct MarketShelfMetricsTests {
    private typealias Metrics = MarketShelfMetrics

    @Test func aShelfIsItsHeaderAGapAndItsLane() {
        let card: CGFloat = 156
        #expect(Metrics.laneHeight(card: card) == card + Metrics.laneTop + Metrics.laneBottom)
        #expect(Metrics.shelfHeight(card: card) == Metrics.headerHeight + Metrics.headerGap + Metrics.laneHeight(card: card))
    }

    @Test func theRoomForTheHoverShadowIsInsideTheLane() {
        // The lane clips: the lift (1.5) and the shadow (12 blur, 7 down) of a hovered card must fit.
        #expect(Metrics.laneTop >= 1.5)
        #expect(Metrics.laneBottom >= 7 + 12)
    }

    @Test func aConnectedCardGrowsWithTheLinesItHas() {
        let plain = Metrics.connectedCardHeight(hasStats: false, hasUpdate: false, needsLogin: false)
        #expect(Metrics.connectedCardHeight(hasStats: true, hasUpdate: false, needsLogin: false) > plain)
        #expect(Metrics.connectedCardHeight(hasStats: false, hasUpdate: true, needsLogin: false) > plain)
        #expect(Metrics.connectedCardHeight(hasStats: false, hasUpdate: false, needsLogin: true) > plain)
        #expect(
            Metrics.connectedCardHeight(hasStats: true, hasUpdate: true, needsLogin: true)
                > Metrics.connectedCardHeight(hasStats: true, hasUpdate: true, needsLogin: false))
    }

    @Test func aStepIsACardAndAGap() {
        #expect(Metrics.pitch == Metrics.cardWidth + Metrics.gap)
    }
}

@Suite struct MarketShelfScrollTests {
    /// A row of 10 cards in a 1000 pt box with the 30 pt page margins, at `offset`.
    private func row(_ offset: CGFloat, container: CGFloat = 1000, cards: Int = 10) -> MarketShelfScroll {
        let pitch = MarketShelfMetrics.pitch
        return MarketShelfScroll(
            offset: offset, container: container, content: CGFloat(cards) * pitch - MarketShelfMetrics.gap,
            leadingInset: 30, trailingInset: 30)
    }

    @Test func atTheStartThereIsNothingBehind() {
        let scroll = row(-30)
        #expect(!scroll.canBack)
        #expect(scroll.canForward)
        #expect(scroll.overflows)
    }

    @Test func atTheEndThereIsNothingAhead() {
        let end = row(0).maxOffset
        #expect(row(end).canBack)
        #expect(!row(end).canForward)
    }

    @Test func inTheMiddleBothShow() {
        #expect(row(500).canBack)
        #expect(row(500).canForward)
    }

    @Test func aRowThatFitsHasNoArrows() {
        let few = row(-30, container: 1000, cards: 3)
        #expect(!few.canBack)
        #expect(!few.canForward)
        #expect(!few.overflows)
    }

    @Test func aRowNotMeasuredYetShowsNothing() {
        let blank = MarketShelfScroll()
        #expect(!blank.canBack)
        #expect(!blank.canForward)
        #expect(blank.pageIndex(forward: true, count: 5) == 1)
    }

    @Test func aScreenfulIsTheWholeCardsBetweenTheMargins() {
        // 940 pt of room, 274 pt a step: three cards (3 x 260 + 2 x 14 = 808; four would need 1082).
        #expect(row(0).screenful() == 3)
        #expect(row(0, container: 200).screenful() == 1)
        #expect(MarketShelfScroll(offset: 0, container: .nan, content: 1, leadingInset: 0, trailingInset: 0).screenful() == 1)
    }

    @Test func anArrowMovesByAScreenfulFromTheNearestCard() {
        // At the start the nearest card is the first: forward goes to the fourth, back stays on the first.
        #expect(row(-30).pageIndex(forward: true, count: 10) == 3)
        #expect(row(-30).pageIndex(forward: false, count: 10) == 0)
        // A row dragged to about the middle of the third card counts from it (the card nearest to the start edge).
        let pitch = MarketShelfMetrics.pitch
        #expect(row(-30 + pitch * 2 + 40).pageIndex(forward: true, count: 10) == 5)
        #expect(row(-30 + pitch * 5).pageIndex(forward: false, count: 10) == 2)
    }

    @Test func theTargetNeverLeavesTheRow() {
        #expect(row(-30 + MarketShelfMetrics.pitch * 8).pageIndex(forward: true, count: 10) == 9)
        #expect(row(-30).pageIndex(forward: true, count: 2) == 1)
        #expect(row(-30).pageIndex(forward: true, count: 0) == nil)
        #expect(MarketShelfScroll(offset: .nan).pageIndex(forward: true, count: 4) == nil)
    }
}

@Suite struct MarketSidebarLogicTests {
    @Test func aRowSetsItsOwnFilterOnEveryPage() {
        for row in [MarketFilter.all, .connected, .installed, .myBots, .category("dev")] {
            #expect(MarketSidebarLogic.target(for: row) == row)
        }
    }

    @Test func onlyCategoriesCarryASymbol() {
        #expect(MarketSidebarLogic.symbol(of: .category("dev")) == MarketCategory.symbol("dev"))
        #expect(MarketSidebarLogic.symbol(of: .all) == nil)
        #expect(MarketSidebarLogic.symbol(of: .connected) == nil)
    }

    @Test func theSetsPageIsAFilterOfItsOwnThatNoRowLights() {
        #expect(MarketFilter.bundles.id == "bundles")
        #expect(!MarketTab.bots.filterRows(categories: ["dev"]).contains(.bundles))
        #expect(MarketFilter.bundles != .all)
    }
}
