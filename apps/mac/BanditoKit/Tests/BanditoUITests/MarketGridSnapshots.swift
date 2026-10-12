import BanditoDesign
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the shelves of the Services page and a category's page to PNG, to look at the headers, the edges, the even
/// rows and the buttons. The real shelves scroll sideways; ScrollView does not render offscreen, so a shelf is drawn here
/// as a plain row cut by the window's edge.
@MainActor
@Suite struct MarketGridSnapshots {
    private static func template(
        _ id: String, _ name: String, _ category: String, _ description: String, accent: String, publisher: String? = "Official"
    ) -> IntegrationCatalogEntry {
        IntegrationCatalogEntry(
            id: id, name: name, descriptionEn: description, descriptionRu: description, kind: .http,
            url: "https://example.com/\(id)", docsUrl: "", icon: "globe", category: category, accent: accent,
            publisher: publisher)
    }

    static let catalog: [IntegrationCatalogEntry] = [
        template("github", "GitHub", "dev", "Repositories, issues and pull requests: read code, open a pull request, review a diff.", accent: "#24292F"),
        template("sentry", "Sentry", "dev", "Errors and performance: find the new errors of the release and what broke.", accent: "#362D59"),
        template("playwright", "Playwright", "dev", "Drive a browser: open pages, click, fill forms and take screenshots to check a change.", accent: "#2EAD33"),
        template("linear", "Linear", "productivity", "Issues and projects of the team.", accent: "#5E6AD2"),
        template("notion", "Notion", "productivity", "Search and edit pages and databases of the workspace, with a very long description that goes over the three lines of a card and must end with an ellipsis, not in the middle of a word.", accent: "#2F3437"),
        template("postgres", "Postgres", "data", "Read-only SQL over a database. Supercalifragilisticexpialidocious_identifiers_without_spaces_are_cut_at_the_edge.", accent: "#336791", publisher: nil),
        template("brave", "Brave Search", "web", "Web search for the agents.", accent: "#FB542B"),
        template("fetch", "Fetch", "web", "Read a web page as clean text.", accent: "#6B7280"),
        template("figma", "Figma", "design", "Frames and styles of a file.", accent: "#A259FF"),
        template("misc", "Misc", "other", "Something else.", accent: "#8D6E4C"),
    ]

    static let integrations = [
        Integration(id: "i1", name: "github", kind: .http, url: "https://example.com/github"),
        Integration(id: "i2", name: "linear", kind: .http, url: "https://example.com/linear"),
        Integration(id: "i3", name: "my-tool", kind: .stdio, command: "/usr/local/bin/mytool", args: ["--stdio"]),
    ]

    private let actions = MarketCardActions(
        open: { _ in }, connect: { _ in }, configure: { _ in }, check: { _ in }, remove: { _ in },
        signInAgain: { _ in }, setEnabled: { _, _ in }, update: { _ in })

    /// A shelf as it looks, without the scroll view (ScrollView does not render offscreen): the header over a row of cards
    /// of the shelf's size, started at the page margin and cut by the window's edge.
    private func shelf<Item: Identifiable, Card: View>(
        _ title: String, _ symbol: String, count: Int, items: [Item], cardHeight: CGFloat, width: CGFloat,
        onAll: (() -> Void)? = {}, @ViewBuilder card: @escaping (Item) -> Card
    ) -> some View {
        VStack(alignment: .leading, spacing: MarketShelfMetrics.headerGap) {
            MarketShelfHeader(title: title, symbol: symbol, count: count, onAll: onAll)
            HStack(alignment: .top, spacing: MarketShelfMetrics.gap) {
                ForEach(items) { item in
                    card(item).frame(width: MarketShelfMetrics.cardWidth, height: cardHeight)
                }
            }
            .padding(.leading, MarketGridLayout.sidePadding)
            .padding(.top, MarketShelfMetrics.laneTop)
            .padding(.bottom, MarketShelfMetrics.laneBottom)
            .frame(width: width, alignment: .leading)
            .clipped()
        }
    }

    private func showcase(width: CGFloat) -> some View {
        let entries = MarketLogic.entries(catalog: Self.catalog, integrations: Self.integrations, languageCode: "en")
        let shelves = MarketSections.shelves(entries, recommended: 1)
        return VStack(alignment: .leading, spacing: MarketShelfMetrics.shelfGap) {
            ForEach(shelves) { section in
                switch section.kind {
                case .connected:
                    shelf(
                        "Connected", section.symbol, count: section.count, items: section.entries,
                        cardHeight: MarketShelfMetrics.connectedCardHeight(hasStats: true, hasUpdate: false, needsLogin: false),
                        width: width
                    ) { entry in
                        if let integration = entry.integration {
                            MarketConnectedCard(
                                entry: entry, integration: integration, status: .connected(tools: 12),
                                statsLine: "12 calls today", updating: false, checking: false, actions: actions)
                        }
                    }
                case .recommended:
                    shelf(
                        "Suited to the project of Boss", section.symbol, count: 1,
                        items: [
                            RecommendationLogic.Item(
                                template: Self.catalog[0], reasonKey: "vercel", evidence: "apps/web/vercel.json")
                        ],
                        cardHeight: MarketShelfMetrics.suggestionCardHeight, width: width, onAll: nil
                    ) { item in
                        RecommendationCard(item: item, onConnect: {})
                    }
                default:
                    shelf(
                        MarketCategory.title(section.categoryName ?? "other"), section.symbol, count: section.count,
                        items: section.entries, cardHeight: MarketShelfMetrics.catalogCardHeight, width: width
                    ) { entry in
                        MarketCatalogCard(entry: entry, actions: actions)
                    }
                }
            }
        }
        .padding(.top, MarketShelfMetrics.topInset)
        .frame(width: width, alignment: .topLeading)
        .background(Color.Bandito.bg)
    }

    private func categoryPage(columns: Int, width: CGFloat) -> some View {
        let entries = MarketLogic.entries(catalog: Self.catalog, integrations: Self.integrations, languageCode: "en")
        let dev = entries.filter { $0.category == "dev" }
        return VStack(alignment: .leading, spacing: 18) {
            MarketPageHeader(
                title: MarketCategory.title("dev"), symbol: MarketCategory.symbol("dev"), count: dev.count, onBack: {})
            MarketRowList(items: dev, columns: columns, rowHeight: MarketShelfMetrics.catalogCardHeight, inset: 30) { entry in
                MarketCatalogCard(entry: entry, actions: actions)
            }
        }
        .padding(.top, MarketShelfMetrics.topInset)
        .frame(width: width, alignment: .topLeading)
        .background(Color.Bandito.bg)
    }

    @Test func showcaseWide() throws {
        let url = try SnapshotSupport.render(showcase(width: 1000), "market-showcase", size: CGSize(width: 1000, height: 1250))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func showcaseNarrow() throws {
        let url = try SnapshotSupport.render(showcase(width: 604), "market-showcase-narrow", size: CGSize(width: 604, height: 1250))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func categoryPageTwoColumns() throws {
        let url = try SnapshotSupport.render(categoryPage(columns: 2, width: 640), "market-category-2", size: CGSize(width: 640, height: 620))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func categoryPageFourColumns() throws {
        let url = try SnapshotSupport.render(categoryPage(columns: 4, width: 1100), "market-category-4", size: CGSize(width: 1100, height: 420))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
