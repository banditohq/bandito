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

    /// The identity the scroll view knows the block by: what `ForEach` takes as the element id and what a jump scrolls to.
    var scrollID: String { id }

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

// MARK: - sizes

/// The fixed sizes of the Services page. Heights are fixed on purpose (an even row, a stable header), but nothing here
/// decides where the page scrolls: jumps go to the anchor of a block, and the block in view comes from where the
/// anchors really are (`MarketSectionTracker`).
enum MarketSectionMetrics {
    /// The pinned header of a block.
    static let headerHeight: CGFloat = 44
    /// A catalog card: the tile and name, two lines, the foot with one button.
    static let cardHeight: CGFloat = 156
    /// The space under every row of cards.
    static let rowGap: CGFloat = MarketGridLayout.gap
    /// The space under the last row of a block, before the next header.
    static let sectionGap: CGFloat = 12
    /// The space above the first block.
    static let topInset: CGFloat = 6

    /// The height of a block of catalog cards: its header, its rows, the gap after it.
    static func height(cards: Int, columns: Int) -> CGFloat {
        headerHeight + CGFloat(MarketGridLayout.rowCount(items: cards, columns: columns)) * (cardHeight + rowGap) + sectionGap
    }

    /// The space to leave under the last block so that it, short as it may be, can be scrolled to the top (and never less
    /// than a margin).
    static func bottomPadding(viewport: CGFloat, last: CGFloat, minimum: CGFloat = 24) -> CGFloat {
        max(minimum, viewport - last)
    }
}

/// Where the header of a block sits while the block is under it, as an offset from the block's top: zero before the
/// block reaches the top of the scroll view, then as far down as the block has scrolled past, and no further than leaves
/// the header at the bottom of the block (the next block's header pushes it out there, as native pinned headers do).
enum MarketStickyOffset {
    static func offset(sectionMinY: CGFloat, sectionHeight: CGFloat, headerHeight: CGFloat = MarketSectionMetrics.headerHeight) -> CGFloat {
        guard sectionMinY.isFinite, sectionHeight.isFinite else { return 0 }
        return min(max(-sectionMinY, 0), max(sectionHeight - headerHeight, 0))
    }
}

/// Which block is in view, from the positions the blocks report (the top edge of each, in the scroll view). A block has
/// passed when its top is no lower than the bottom of the pinned header (the next header takes over there). The block in
/// view is the last one passed. A jump sets the flags itself (`jump(to:)`), so the blocks it flies over are not reported.
@MainActor
final class MarketSectionTracker {
    /// How far below the top an anchor may be and still count as passed.
    static let threshold = MarketSectionMetrics.headerHeight + 1

    private var ids: [String] = []
    private var passed: [Bool] = []
    /// Until then a change of the block in view is not reported (a jump passes the blocks between).
    var quietUntil: TimeInterval = 0
    private var lastReported: Int?

    var active: Int? { passed.lastIndex(of: true) }

    /// Starts over for these blocks (the list changed, or the page was shown again).
    func configure(ids new: [String]) {
        guard new != ids else { return }
        reset(ids: new)
    }

    func reset(ids new: [String]? = nil) {
        if let new { ids = new }
        passed = Array(repeating: false, count: ids.count)
        lastReported = nil
    }

    /// An anchor moved. Returns true when the block in view changed and may be reported.
    func report(index: Int, minY: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard passed.indices.contains(index) else { return false }
        passed[index] = CGFloat(minY) <= Self.threshold
        guard active != lastReported else { return false }
        lastReported = active
        return now >= quietUntil
    }

    /// A jump to block `index` (nil: the top): the blocks up to it count as passed, the ones after it as not.
    func jump(to index: Int?) {
        for i in passed.indices { passed[i] = index.map { i <= $0 } ?? false }
        lastReported = active
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

    /// Where a target lands: the top, or the block of a category. Nil when there is no such block (an empty category).
    static func landing(of target: MarketScrollTarget, sections: [MarketSection]) -> MarketLanding? {
        switch target {
        case .top: return .top
        case .category(let name):
            return sections.firstIndex { $0.categoryName == name }.map { .section($0) }
        }
    }
}

extension MarketSidebarLogic {
    /// The id a jump hands to `scrollTo`: the top's, or the `scrollID` of the block (the element id of the page's `ForEach`).
    static func scrollID(for landing: MarketLanding, sections: [MarketSection]) -> String {
        switch landing {
        case .top: MarketScrollDriver.topID
        case .section(let index): sections[index].scrollID
        }
    }
}

enum MarketLanding: Equatable {
    case top
    case section(Int)

    var index: Int? {
        if case .section(let index) = self { return index }
        return nil
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
