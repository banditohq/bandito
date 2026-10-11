import BanditoDesign
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the blocks of the Services page to PNG at 2 and 4 columns, to look at the edges, the even rows and the
/// buttons. The real page scrolls; ScrollView does not render offscreen, so the blocks are stacked in a plain VStack here.
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

    private func page(columns: Int, width: CGFloat) -> some View {
        let entries = MarketLogic.entries(catalog: Self.catalog, integrations: Self.integrations, languageCode: "en")
        let sections = MarketSections.sections(entries)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                MarketSectionHeader(title: title(of: section), count: section.entries.count, tone: .of(section))
                if section.kind == .connected {
                    MarketRowList(items: section.entries, columns: columns, rowHeight: nil, inset: 30) { entry in
                        if let integration = entry.integration {
                            MarketConnectedCard(
                                entry: entry, integration: integration, status: .connected(tools: 12),
                                statsLine: "12 calls today", updating: false, checking: false, actions: actions)
                        }
                    }
                } else {
                    MarketRowList(items: section.entries, columns: columns, rowHeight: MarketSectionMetrics.cardHeight, inset: 30) { entry in
                        MarketCatalogCard(entry: entry, actions: actions)
                    }
                }
                Color.clear.frame(height: MarketSectionMetrics.sectionGap)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .background(Color.Bandito.bg)
    }

    private func title(of section: MarketSection) -> String {
        switch section.kind {
        case .connected: "Connected"
        case .category(let name): MarketCategory.title(name)
        case .catalog: "Catalog"
        }
    }

    @Test func twoColumns() throws {
        let url = try SnapshotSupport.render(page(columns: 2, width: 640), "market-grid-2", size: CGSize(width: 640, height: 2900))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fourColumns() throws {
        let url = try SnapshotSupport.render(page(columns: 4, width: 1100), "market-grid-4", size: CGSize(width: 1100, height: 2000))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
