import BanditoKit
import Foundation

/// One block of the Services page under the All filter: the connected services, or the services of one category.
struct MarketSection: Identifiable, Equatable {
    enum Kind: Hashable {
        /// The connected services (the rich cards), always first.
        case connected
        /// A category of the catalog: `dev`, `productivity`, ...
        case category(String)
        /// A catalog from a daemon that sends no categories at all: one block for everything.
        case catalog
    }

    let kind: Kind
    var entries: [MarketEntry]

    var id: String {
        switch kind {
        case .connected: "connected"
        case .category(let name): "category:\(name)"
        case .catalog: "catalog"
        }
    }

    /// The category name of a category section; nil for the others.
    var categoryName: String? {
        if case .category(let name) = kind { return name }
        return nil
    }
}

/// What the Services page shows for a filter and a search.
enum MarketContent: Equatable {
    /// All filter, no search: the connected block, then one block per category.
    case sections([MarketSection])
    /// A search, or the Connected filter: one plain list without blocks, and why it may be empty.
    case flat([MarketEntry], MarketEmptyState?)
}

/// The rules of the sectioned Services page. Pure, so the order, the grouping and the jump targets are easy to test.
enum MarketSections {
    /// The word a template without a category goes under, when the catalog has categories at all.
    static let fallbackCategory = "other"

    /// The category key of a catalog entry: its own, else `other`. Nil for an own integration (it is in no category),
    /// and nil for every entry when the catalog has no categories at all (an older daemon).
    static func categoryKey(of entry: MarketEntry, catalogHasCategories: Bool) -> String? {
        guard !entry.isOwn, catalogHasCategories else { return nil }
        return entry.template?.category ?? fallbackCategory
    }

    static func hasCategories(_ entries: [MarketEntry]) -> Bool {
        entries.contains { !$0.isOwn && $0.template?.category != nil }
    }

    /// The blocks of the All page. The connected services come first (including the owner's own integrations). The
    /// categories follow in the sidebar order, each with all its catalog services whether connected or not (a connected
    /// one shows its mark), and an empty category has no block. A category the daemon adds later comes after the known
    /// ones, in alphabetical order. A catalog with no categories is one `catalog` block.
    static func sections(_ entries: [MarketEntry]) -> [MarketSection] {
        var result: [MarketSection] = []
        let connected = entries.filter(\.isConnected)
        if !connected.isEmpty { result.append(MarketSection(kind: .connected, entries: connected)) }

        let catalogEntries = entries.filter { !$0.isOwn }
        guard !catalogEntries.isEmpty else { return result }
        let hasCategories = hasCategories(entries)
        guard hasCategories else {
            result.append(MarketSection(kind: .catalog, entries: catalogEntries))
            return result
        }
        var byCategory: [String: [MarketEntry]] = [:]
        for entry in catalogEntries {
            byCategory[categoryKey(of: entry, catalogHasCategories: true) ?? fallbackCategory, default: []].append(entry)
        }
        for name in orderedCategories(Set(byCategory.keys)) {
            if let list = byCategory[name], !list.isEmpty {
                result.append(MarketSection(kind: .category(name), entries: list))
            }
        }
        return result
    }

    /// The sidebar order of a set of category names: the known ones first, then the rest alphabetically.
    static func orderedCategories(_ used: Set<String>) -> [String] {
        MarketCategory.order.filter { used.contains($0) } + used.subtracting(MarketCategory.order).sorted()
    }

    /// What the page shows. Under All with no search: the blocks. A search: one flat list of what matches (the filter
    /// still narrows it). The Connected filter: the connected services, flat.
    static func content(_ entries: [MarketEntry], filter: MarketFilter, query: String) -> MarketContent {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !searching, filter == .all { return .sections(sections(entries)) }
        let shown = MarketLogic.visible(entries, filter: filter, query: query)
        if shown.isEmpty {
            if searching { return .flat([], .noResults) }
            return .flat([], filter == .connected ? .nothingConnected : nil)
        }
        return .flat(shown, nil)
    }
}

// MARK: - grid

/// How many cards sit in a row, and how a list of cards is cut into rows. The window decides the columns; the cards
/// share the width evenly, so the grid fills its box with the same margin at both ends.
enum MarketGridLayout {
    /// The space between cards, across and down.
    static let gap: CGFloat = 14
    /// The margin of the page at both sides.
    static let sidePadding: CGFloat = 30
    /// The narrowest a card may get before the grid drops a column.
    static let minCardWidth: CGFloat = 232
    static let columnRange = 2...4

    /// The columns for a content width: as many as fit with `minCard`, kept between 2 and 4.
    static func columns(
        contentWidth: CGFloat, minCard: CGFloat = minCardWidth, range: ClosedRange<Int> = columnRange
    ) -> Int {
        guard contentWidth.isFinite, contentWidth > 0 else { return range.lowerBound }
        let fit = Int(((contentWidth + gap) / (minCard + gap)).rounded(.down))
        return min(max(fit, range.lowerBound), range.upperBound)
    }

    /// The columns for the width of the scroll view (the page margins are taken off).
    static func columns(scrollWidth: CGFloat) -> Int {
        columns(contentWidth: scrollWidth - 2 * sidePadding)
    }

    /// The width of one card of a row.
    static func cardWidth(contentWidth: CGFloat, columns: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        return (contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
    }

    /// The items cut into rows of `columns`; the last row may be short. No items, no rows.
    static func rows<T>(_ items: [T], columns: Int) -> [[T]] {
        let size = max(columns, 1)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    static func rowCount(items: Int, columns: Int) -> Int {
        guard items > 0 else { return 0 }
        let size = max(columns, 1)
        return (items + size - 1) / size
    }
}

// MARK: - positions

/// Where each block of the Services page starts in the scroll content, and which block is in view. The heights of the
/// pinned header and of the catalog rows are fixed on purpose, so the starts are sums, not measurements; only the
/// content above the first category (the connected cards and the suggestions row) is measured and passed in.
struct MarketSectionMetrics: Equatable {
    /// The pinned header of a block.
    static let headerHeight: CGFloat = 44
    /// A catalog card.
    static let cardHeight: CGFloat = 190
    /// The space under every row of cards.
    static let rowGap: CGFloat = MarketGridLayout.gap
    /// The space under the last row of a block, before the next header.
    static let sectionGap: CGFloat = 12
    /// The space above the first block.
    static let topInset: CGFloat = 6

    /// One block, as far as the positions are concerned.
    struct Shape: Equatable {
        let id: String
        /// How many cards the block has (catalog blocks).
        let cards: Int
        /// The measured height of the block's content when its cards are not of the fixed height (the connected block).
        var measuredContent: CGFloat?
    }

    /// The height of a block: its header, its rows, the gap after it.
    static func height(of shape: Shape, columns: Int) -> CGFloat {
        let content =
            shape.measuredContent
            ?? CGFloat(MarketGridLayout.rowCount(items: shape.cards, columns: columns)) * (cardHeight + rowGap)
        return headerHeight + content + sectionGap
    }

    /// The start of each block, from the top of the scroll content. `leading` is the content above the first block.
    static func starts(_ shapes: [Shape], columns: Int, leading: CGFloat = 0) -> [CGFloat] {
        var y = topInset + leading
        var result: [CGFloat] = []
        for shape in shapes {
            result.append(y)
            y += height(of: shape, columns: columns)
        }
        return result
    }

    /// The index of the block whose header is pinned at the top when the content is scrolled to `offset`. A block takes
    /// over when its header reaches the bottom of the pinned one. Nil above the first block.
    static func activeIndex(offset: CGFloat, starts: [CGFloat]) -> Int? {
        var active: Int?
        for (index, start) in starts.enumerated() where start <= offset + headerHeight {
            active = index
        }
        return active
    }

    /// The space to leave under the last block so that every block, the short last one too, can be scrolled to the top
    /// (and never less than a margin).
    static func bottomPadding(viewport: CGFloat, last: CGFloat, minimum: CGFloat = 24) -> CGFloat {
        max(minimum, viewport - last)
    }
}

// MARK: - jumping from the sidebar

/// Where a click in the sidebar sends the Services page.
enum MarketScrollTarget: Hashable {
    case top
    case category(String)
}

/// A request to scroll the Services page. The id makes a second click on the same row a new request.
struct MarketScrollRequest: Equatable {
    let id: Int
    let target: MarketScrollTarget
    /// When it was made (system uptime, seconds). A request that waited too long for the page is dropped, so a click
    /// from long ago does not move the page when the catalog finally loads.
    let created: TimeInterval

    init(id: Int, target: MarketScrollTarget, created: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.id = id
        self.target = target
        self.created = created
    }

    static let lifetime: TimeInterval = 8

    func isFresh(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - created < Self.lifetime
    }

    var isFresh: Bool { isFresh() }
}

/// What a click on a sidebar row of the Services page does.
enum MarketSidebarAction: Equatable {
    /// Set the filter (the flat Connected page).
    case filter(MarketFilter)
    /// Go to the sectioned page and scroll to a place on it.
    case scroll(MarketScrollTarget)
}

enum MarketSidebarLogic {
    /// The action of a row. On the Services page All and the categories scroll the sectioned page (leaving a filter if
    /// one is set); Connected is a filter of its own. The other pages filter as before.
    static func action(for row: MarketFilter, tab: MarketTab) -> MarketSidebarAction {
        guard tab == .services else { return .filter(row) }
        switch row {
        case .all: return .scroll(.top)
        case .category(let name): return .scroll(.category(name))
        default: return .filter(row)
        }
    }

    /// The row to light. Under All it follows the scroll: the block in view; the top and the connected block light All.
    static func highlighted(tab: MarketTab, filter: MarketFilter, section: String?) -> MarketFilter {
        guard tab == .services, filter == .all || filter.isCategory else { return filter }
        if let section { return .category(section) }
        return .all
    }

    /// The scroll offset of a target, or nil when there is no such block (an empty category).
    static func offset(of target: MarketScrollTarget, sections: [MarketSection], starts: [CGFloat]) -> CGFloat? {
        switch target {
        case .top: return 0
        case .category(let name):
            guard let index = sections.firstIndex(where: { $0.categoryName == name }), index < starts.count else { return nil }
            return starts[index]
        }
    }
}

extension MarketFilter {
    var isCategory: Bool {
        if case .category = self { return true }
        return false
    }
}

// MARK: - tones

/// The calm accent of a block, as a name; the view maps it to a color of the design system.
enum MarketTone: Equatable {
    case connected, sky, peach, lilac, rose, cream, neutral
    /// A category the app has no color for: a palette entry picked by the name.
    case hashed(Int)

    /// The tone of a block: the known categories keep their color, the others take a stable one from the name.
    static func of(_ section: MarketSection) -> MarketTone {
        switch section.kind {
        case .connected: return .connected
        case .catalog: return .neutral
        case .category(let name): return of(category: name)
        }
    }

    static func of(category name: String) -> MarketTone {
        switch name {
        case "dev": .sky
        case "productivity": .peach
        case "data": .lilac
        case "web": .rose
        case "design": .cream
        case "other": .neutral
        default: .hashed(MarketTileStyle.paletteIndex(for: name))
        }
    }
}
