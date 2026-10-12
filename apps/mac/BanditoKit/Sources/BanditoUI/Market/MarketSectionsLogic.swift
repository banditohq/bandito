import BanditoKit
import Foundation

// The rules of the Marketplace showcase: which shelves the Services page has and in what order, what a category's page
// holds, how the shelves and the grid are measured, and the arithmetic of a shelf's arrows. Pure, so each rule is
// tested without a view.

/// One shelf of the Services page under All: a header and a row of cards that scrolls sideways.
struct MarketShelf: Identifiable, Equatable {
    enum Kind: Hashable {
        /// The connected services (the rich cards), always first.
        case connected
        /// What the daemon suggests for the project of the agent on screen. Right after the connected shelf, or first.
        case recommended
        /// A category of the catalog: `dev`, `productivity`, ...
        case category(String)
        /// A catalog from a daemon that sends no categories at all: one block for everything, not a shelf (nothing to
        /// open with "All").
        case catalog
    }

    let kind: Kind
    /// The services of the shelf. Empty for the suggestions: they are not entries, the page holds them.
    var entries: [MarketEntry]
    /// The number in the header: the cards the shelf holds.
    let count: Int

    init(kind: Kind, entries: [MarketEntry], count: Int? = nil) {
        self.kind = kind
        self.entries = entries
        self.count = count ?? entries.count
    }

    var id: String {
        switch kind {
        case .connected: "connected"
        case .recommended: "recommended"
        case .category(let name): "category:\(name)"
        case .catalog: "catalog"
        }
    }

    /// The category name of a category shelf; nil for the others.
    var categoryName: String? {
        if case .category(let name) = kind { return name }
        return nil
    }

    /// The symbol in front of the shelf's name.
    var symbol: String {
        switch kind {
        case .connected: MarketShelfSymbol.connected
        case .recommended: MarketShelfSymbol.recommended
        case .category(let name): MarketCategory.symbol(name)
        case .catalog: MarketCategory.symbol("other")
        }
    }

    /// The filter that "All" in the header opens. Nil: the shelf has no page of its own.
    var destination: MarketFilter? {
        switch kind {
        case .connected: .connected
        case .category(let name): .category(name)
        case .recommended, .catalog: nil
        }
    }
}

/// A shelf of the Bots or Skills page: the items of one category.
struct MarketCategoryShelf<Item: Identifiable>: Identifiable {
    let category: String
    let items: [Item]

    var id: String { category }
}

extension MarketCategoryShelf: Equatable where Item: Equatable {}

extension MarketCategoryShelf {
    /// The items grouped by category, one shelf per category that has any, in `order` and then the others alphabetically.
    /// The items of a shelf keep the order they came in.
    static func group(_ items: [Item], category: (Item) -> String, order: [String]) -> [MarketCategoryShelf<Item>] {
        var byCategory: [String: [Item]] = [:]
        for item in items { byCategory[category(item), default: []].append(item) }
        let used = Set(byCategory.keys)
        let names = order.filter { used.contains($0) } + used.subtracting(order).sorted()
        return names.compactMap { name in
            byCategory[name].map { MarketCategoryShelf(category: name, items: $0) }
        }
    }
}

/// The symbols of the shelves that are not categories.
enum MarketShelfSymbol {
    static let connected = "checkmark.circle"
    static let recommended = "sparkles"
    static let bundles = "square.stack.3d.up"
    static let ownSkills = "wand.and.stars"
}

/// A page that lists one thing in full: reached with "All" on a shelf, or from the sidebar.
enum MarketPageKind: Hashable {
    case connected
    case category(String)

    var filter: MarketFilter {
        switch self {
        case .connected: .connected
        case .category(let name): .category(name)
        }
    }

    var symbol: String {
        switch self {
        case .connected: MarketShelfSymbol.connected
        case .category(let name): MarketCategory.symbol(name)
        }
    }

    var title: String { filter.title }
}

/// What the Services page shows for a filter and a search.
enum MarketContent: Equatable {
    /// All filter, no search: the shelves.
    case shelves([MarketShelf])
    /// The page of the connected services or of a category (the search narrows it): a header with Back and a grid.
    case page(MarketPageKind, [MarketEntry], MarketEmptyState?)
    /// A search under All: one plain grid of what matches, and why it may be empty.
    case flat([MarketEntry], MarketEmptyState?)
}

/// How a Marketplace page (Services, Bots or Skills) lays itself out for a filter and a search.
enum MarketPageMode: Equatable {
    /// Under All with no search: shelves.
    case shelves
    /// A category (or the connected services, or the sets): its own page with a header and a Back.
    case page
    /// A search under All, or a filter that has no page of its own (installed skills, my bots): a plain grid.
    case flat

    static func of(filter: MarketFilter, searching: Bool) -> MarketPageMode {
        switch filter {
        case .all: searching ? .flat : .shelves
        case .connected, .category, .bundles: .page
        case .installed, .myBots: .flat
        }
    }
}

/// The rules of the sectioned Services page. Pure, so the order, the grouping and the pages are easy to test.
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

    /// The shelves of the All page. The connected services come first (including the owner's own integrations), then the
    /// suggestions when there are `recommended` of them, then one shelf per category in the sidebar order, each with all
    /// its catalog services whether connected or not (a connected one shows its mark). An empty category has no shelf. A
    /// category the daemon adds later comes after the known ones, in alphabetical order. A catalog with no categories
    /// is one `catalog` block.
    static func shelves(_ entries: [MarketEntry], recommended: Int = 0) -> [MarketShelf] {
        var result: [MarketShelf] = []
        let connected = entries.filter(\.isConnected)
        if !connected.isEmpty { result.append(MarketShelf(kind: .connected, entries: connected)) }
        if recommended > 0 { result.append(MarketShelf(kind: .recommended, entries: [], count: recommended)) }

        let catalogEntries = entries.filter { !$0.isOwn }
        guard !catalogEntries.isEmpty else { return result }
        guard hasCategories(entries) else {
            result.append(MarketShelf(kind: .catalog, entries: catalogEntries))
            return result
        }
        var byCategory: [String: [MarketEntry]] = [:]
        for entry in catalogEntries {
            byCategory[categoryKey(of: entry, catalogHasCategories: true) ?? fallbackCategory, default: []].append(entry)
        }
        for name in orderedCategories(Set(byCategory.keys)) {
            if let list = byCategory[name], !list.isEmpty {
                result.append(MarketShelf(kind: .category(name), entries: list))
            }
        }
        return result
    }

    /// The sidebar order of a set of category names: the known ones first, then the rest alphabetically.
    static func orderedCategories(_ used: Set<String>) -> [String] {
        MarketCategory.order.filter { used.contains($0) } + used.subtracting(MarketCategory.order).sorted()
    }

    /// What the page shows. Under All with no search: the shelves. A search under All: one flat list of what matches.
    /// The Connected filter and a category: that page, narrowed by the search.
    static func content(_ entries: [MarketEntry], filter: MarketFilter, query: String, recommended: Int = 0)
        -> MarketContent
    {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shown = MarketLogic.visible(entries, filter: filter, query: query)
        let empty: MarketEmptyState? =
            shown.isEmpty ? (searching ? .noResults : (filter == .connected ? .nothingConnected : nil)) : nil
        switch MarketPageMode.of(filter: filter, searching: searching) {
        case .shelves:
            return .shelves(shelves(entries, recommended: recommended))
        case .page:
            switch filter {
            case .connected: return .page(.connected, shown, empty)
            case .category(let name): return .page(.category(name), shown, empty)
            default: return .flat(shown, empty)
            }
        case .flat:
            return .flat(shown, empty)
        }
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

// MARK: - sizes

/// The fixed sizes of the showcase. A shelf is a lazy row, and a lazy row cannot ask the cards it has not built how tall
/// they are, so every shelf has one fixed card height and every card has one fixed width.
enum MarketShelfMetrics {
    /// A card of a shelf.
    static let cardWidth: CGFloat = 260
    /// The space between cards of a shelf.
    static let gap: CGFloat = MarketGridLayout.gap
    /// One step of a shelf: the distance between two card edges, which is where it snaps.
    static var pitch: CGFloat { cardWidth + gap }
    /// The header of a shelf (symbol, name, number, "All").
    static let headerHeight: CGFloat = 30
    /// The space between a header and its cards.
    static let headerGap: CGFloat = 8
    /// Room above the cards for the 1.5 pt lift of the hovered card, and below them for its shadow. The shelf clips to
    /// its box, so the room is inside it.
    static let laneTop: CGFloat = 6
    static let laneBottom: CGFloat = 22
    /// The space between two shelves, under the room below the cards.
    static let shelfGap: CGFloat = 8
    /// The space above the first shelf.
    static let topInset: CGFloat = 6

    /// A catalog card: the tile and name, two lines, the foot with one button.
    static let catalogCardHeight: CGFloat = 156
    /// A suggestion card: tile and name, the reason, the file, one button.
    static let suggestionCardHeight: CGFloat = 156
    /// A card of a bot template: tile, three lines, the services, one button.
    static let botCardHeight: CGFloat = 200
    /// A set of bots: tile, two lines, the members, one button.
    static let bundleCardHeight: CGFloat = 176
    /// A skill: tile, two lines, chips, a warning line, the foot.
    static let skillCardHeight: CGFloat = 204
    /// One of the owner's own skills.
    static let ownSkillCardHeight: CGFloat = 176

    /// The height of the lane for a card height.
    static func laneHeight(card: CGFloat) -> CGFloat { card + laneTop + laneBottom }

    /// The height of a shelf: header, gap, lane.
    static func shelfHeight(card: CGFloat) -> CGFloat { headerHeight + headerGap + laneHeight(card: card) }

    /// The height of the connected services' cards: the lines every card has (name and address, the check, the switch)
    /// and the ones some cards add (what it was used for, the update, signing in again). The shelf takes the tallest.
    static func connectedCardHeight(hasStats: Bool, hasUpdate: Bool, needsLogin: Bool) -> CGFloat {
        var height: CGFloat = 14 + 32 + 10 + 18 + 10 + 22 + 14
        if hasStats { height += 10 + 16 }
        if hasUpdate { height += 10 + 26 }
        if needsLogin { height += 10 + 28 }
        return height
    }
}

// MARK: - the arrows of a shelf

/// Where a shelf's row is, in the numbers of its scroll view: what decides whether an arrow shows, and where a click on
/// it goes. Plain numbers, so the rule is tested without a window.
struct MarketShelfScroll: Equatable {
    /// The scroll offset (`contentOffset.x`): `-leadingInset` at the start.
    var offset: CGFloat = 0
    /// The width of the visible box.
    var container: CGFloat = 0
    /// The width of the cards and the gaps between them.
    var content: CGFloat = 0
    /// The page margins inside the scroll view.
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var minOffset: CGFloat { -leadingInset }

    var maxOffset: CGFloat { max(minOffset, content + trailingInset - container) }

    var canBack: Bool { offset > minOffset + 1 }

    var canForward: Bool { offset < maxOffset - 1 }

    /// More than one screen of cards: the row has somewhere to go.
    var overflows: Bool { maxOffset > minOffset + 1 }

    /// How many whole cards fit between the page margins (at least one): what a click on an arrow moves by.
    func screenful(pitch: CGFloat = MarketShelfMetrics.pitch) -> Int {
        guard pitch > 0, container.isFinite else { return 1 }
        let room = container - leadingInset - trailingInset
        return max(1, Int(((room + MarketShelfMetrics.gap) / pitch).rounded(.down)))
    }

    /// The card a click on an arrow scrolls to the start of: one screenful of cards from the card nearest to the start
    /// edge now, and never before the first or after the last. Nil when there are no cards.
    func pageIndex(forward: Bool, count: Int, pitch: CGFloat = MarketShelfMetrics.pitch) -> Int? {
        guard count > 0, pitch > 0, offset.isFinite else { return nil }
        let from = Int(((offset - minOffset) / pitch).rounded())
        let to = from + (forward ? screenful(pitch: pitch) : -screenful(pitch: pitch))
        return min(max(to, 0), count - 1)
    }
}

// MARK: - the sidebar

/// What a click on a sidebar row of the Marketplace does. Every page filters the same way now: the row sets the page's
/// filter, and All is the showcase.
enum MarketSidebarLogic {
    /// The filter a click on `row` sets.
    static func target(for row: MarketFilter) -> MarketFilter { row }

    /// The category rows carry their symbol; the others do not.
    static func symbol(of row: MarketFilter) -> String? {
        if case .category(let name) = row { return MarketCategory.symbol(name) }
        return nil
    }
}

extension MarketFilter {
    var isCategory: Bool {
        if case .category = self { return true }
        return false
    }
}
