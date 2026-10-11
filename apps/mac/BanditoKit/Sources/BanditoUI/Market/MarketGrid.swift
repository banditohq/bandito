import AppKit
import BanditoDesign
import SwiftUI

// The shared parts of the Marketplace pages: the grid of cards cut into rows, the pinned block header, the cache of
// rendered tiles, and the scroll driver of the Services page.

// MARK: - columns

private struct MarketColumnsKey: EnvironmentKey {
    static let defaultValue = 3
}

extension EnvironmentValues {
    /// How many cards a row of the Marketplace holds. Set by the page from the width of its scroll view.
    var marketColumns: Int {
        get { self[MarketColumnsKey.self] }
        set { self[MarketColumnsKey.self] = newValue }
    }
}

// MARK: - rows

/// Rows of cards for a stack: the items cut into rows of `columns`, each card taking an equal share of the width, a
/// short last row padded with empty cells so its cards keep the column width. Put it inside a `LazyVStack` (or use
/// `MarketRows`). With a `rowHeight` every row has that height and the cards fill it; without one a row is as tall as
/// its tallest card and the others stretch to it.
struct MarketRowList<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let columns: Int
    var rowHeight: CGFloat?
    /// Space at both sides of a row (the page margin), for rows that sit in a full-width stack.
    var inset: CGFloat = 0
    @ViewBuilder var card: (Item) -> Card

    private struct Row: Identifiable {
        let id: Item.ID
        let items: [Item]
    }

    var body: some View {
        let rows = MarketGridLayout.rows(items, columns: columns).compactMap { items in
            items.first.map { Row(id: $0.id, items: items) }
        }
        ForEach(rows) { row in
            cells(of: row)
                .padding(.horizontal, inset)
                .padding(.bottom, MarketGridLayout.gap)
        }
    }

    @ViewBuilder
    private func cells(of row: Row) -> some View {
        let line = HStack(alignment: .top, spacing: MarketGridLayout.gap) {
            ForEach(0..<max(columns, 1), id: \.self) { column in
                if column < row.items.count {
                    card(row.items[column]).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
        if let rowHeight {
            line.frame(height: rowHeight)
        } else {
            line.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The rows of cards in a lazy stack of their own: for a page whose other content is not a lazy stack (Bots, Skills).
struct MarketRows<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var rowHeight: CGFloat?
    @Environment(\.marketColumns) private var columns
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            MarketRowList(items: items, columns: columns, rowHeight: rowHeight, card: card)
        }
    }
}

// MARK: - actions

/// The actions at the foot of a card: `leading` at the left and `trailing` at the right on one line when they fit, else
/// `trailing` under `leading`. Nothing runs out of the card in a narrow column or with a long translation.
struct MarketActionRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 6) {
                leading
                HStack(spacing: 8) {
                    trailing
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - block header

extension MarketTone {
    /// The color of the tone, from the design system. The brand's pastel avatar colors keep the blocks apart without
    /// shouting; the connected block takes the "working" green.
    var color: Color {
        switch self {
        case .connected: Color.Bandito.ok
        case .sky: BanditoPalette.avatarSky
        case .peach: BanditoPalette.avatarPeach
        case .lilac: BanditoPalette.avatarLilac
        case .rose: BanditoPalette.avatarRose
        case .cream: BanditoPalette.avatarCream
        case .neutral: Color.Bandito.text3
        case .hashed(let index): AvatarColor.allCases[index % AvatarColor.allCases.count].color
        }
    }
}

/// The header of a block of the Services page. It stays at the top while the block scrolls under it: a bar and a soft
/// wash in the block's color, the name, the number of services. Opaque, so cards pass under it without showing through.
struct MarketSectionHeader: View {
    let title: String
    let count: Int
    let tone: MarketTone

    var body: some View {
        let tint = tone.color
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 3, height: 16)
            Text(title.uppercased())
                .font(BanditoFont.display(size: 11, weight: 600))
                .tracking(0.6)
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(count)")
                .font(BanditoFont.text(size: 11.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MarketGridLayout.sidePadding)
        .frame(height: MarketSectionMetrics.headerHeight)
        .background {
            ZStack {
                Color.Bandito.bg
                LinearGradient(
                    colors: [tint.opacity(0.14), tint.opacity(0.02)], startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - measuring

extension View {
    /// Reports the height of the view in whole points, only when it changes.
    func marketMeasuredHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { new in
            if height.wrappedValue != new { height.wrappedValue = new }
        }
    }
}

// MARK: - tiles

/// Tiles drawn once and kept as pictures. A tile is a gradient, a hairline highlight and a glyph with a shadow: with
/// a few dozen of them in a scrolling list, the shadows and the SVG logos were redrawn every frame. A rendered tile is
/// a bitmap, cheap to move. The key says everything that makes the tile look the way it does.
@MainActor
final class MarketTileImages {
    static let shared = MarketTileImages()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    func image<Face: View>(key: String, @ViewBuilder face: () -> Face) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let renderer = ImageRenderer(content: face())
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

// MARK: - the scroll driver of the Services page

/// What the driver needs from the page.
struct MarketScrollContext {
    let sections: [MarketSection]
    let starts: [CGFloat]
    /// The page has been measured and laid out in blocks: a request can be carried out.
    let ready: Bool
    let request: MarketScrollRequest?
    /// The request was taken (carried out or dropped).
    let onHandled: () -> Void
    /// The block in view changed (an index into `sections`, nil above the first).
    let onActive: (Int?) -> Void
}

/// Carries out the sidebar's jumps and reports which block is in view. From macOS 15 it scrolls to an exact offset (the
/// layout of the page is fixed, so the offsets are sums) and watches the offset; before that it asks the proxy to
/// scroll to the block's anchor and cannot follow the scroll.
struct MarketScrollDriver: ViewModifier {
    let context: MarketScrollContext
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(MarketExactScroll(context: context))
        } else {
            content.modifier(MarketProxyScroll(context: context, proxy: proxy))
        }
    }

    /// The id of the zero-height anchor in front of a block; `top` for the very top.
    static func anchorID(_ section: MarketSection) -> String { "market-anchor:\(section.id)" }
    static let topAnchorID = "market-anchor:top"
}

/// What the key of the task that carries out a jump is made of: a new request, or the page becoming ready.
private struct MarketJumpKey: Hashable {
    let requestID: Int?
    let ready: Bool
}

/// The index of the block a jump ends on, nil for the top.
private func marketJumpIndex(_ target: MarketScrollTarget, in sections: [MarketSection]) -> Int? {
    if case .category(let name) = target { return sections.firstIndex { $0.categoryName == name } }
    return nil
}

@available(macOS 15.0, *)
private struct MarketExactScroll: ViewModifier {
    let context: MarketScrollContext

    @State private var position = ScrollPosition()
    /// While a jump animates the blocks it passes are not reported; this is when reporting starts again.
    @State private var quietUntil: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    func body(content: Content) -> some View {
        let starts = context.starts
        content
            .scrollPosition($position)
            // One Int per scroll step, and the action runs only when it changes: a few times in a long scroll.
            .onScrollGeometryChange(for: Int.self) { geometry in
                MarketSectionMetrics.activeIndex(offset: geometry.contentOffset.y, starts: starts) ?? -1
            } action: { _, active in
                guard ProcessInfo.processInfo.systemUptime >= quietUntil else { return }
                context.onActive(active >= 0 ? active : nil)
            }
            .task(id: MarketJumpKey(requestID: context.request?.id, ready: context.ready)) {
                await jump()
            }
    }

    private func jump() async {
        guard context.ready, let request = context.request else { return }
        defer { context.onHandled() }
        guard request.isFresh,
            let offset = MarketSidebarLogic.offset(of: request.target, sections: context.sections, starts: context.starts)
        else { return }
        // The page may have just appeared: let it lay out before moving.
        await Task.yield()
        guard !Task.isCancelled else { return }
        let level = MotionLevel(stored: motionLevel)
        let reduced = level.reducesMotion(systemReduceMotion: reduceMotion)
        context.onActive(marketJumpIndex(request.target, in: context.sections))
        if reduced {
            quietUntil = ProcessInfo.processInfo.systemUptime + 0.15
            position.scrollTo(y: offset)
        } else {
            quietUntil = ProcessInfo.processInfo.systemUptime + level.scaled(0.6)
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: level.scaled(0.45))) {
                position.scrollTo(y: offset)
            }
        }
    }
}

private struct MarketProxyScroll: ViewModifier {
    let context: MarketScrollContext
    let proxy: ScrollViewProxy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    func body(content: Content) -> some View {
        content.task(id: MarketJumpKey(requestID: context.request?.id, ready: context.ready)) {
            await jump()
        }
    }

    private func jump() async {
        guard context.ready, let request = context.request else { return }
        defer { context.onHandled() }
        guard request.isFresh,
            MarketSidebarLogic.offset(of: request.target, sections: context.sections, starts: context.starts) != nil
        else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        let id: String
        let index = marketJumpIndex(request.target, in: context.sections)
        if let index { id = MarketScrollDriver.anchorID(context.sections[index]) } else { id = MarketScrollDriver.topAnchorID }
        context.onActive(index)
        let level = MotionLevel(stored: motionLevel)
        if level.reducesMotion(systemReduceMotion: reduceMotion) {
            proxy.scrollTo(id, anchor: .top)
        } else {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: level.scaled(0.45))) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }
}
