import AppKit
import BanditoDesign
import SwiftUI

// The shared parts of the Marketplace pages: the grid of cards cut into rows and the cache of rendered tiles.

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

/// The rows of cards in a lazy stack of their own: for a page whose other content is not a lazy stack (the grids of
/// Bots and Skills).
struct MarketRows<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var rowHeight: CGFloat?
    /// Space at both sides of a row (the page margin).
    var inset: CGFloat = MarketGridLayout.sidePadding
    @Environment(\.marketColumns) private var columns
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            MarketRowList(items: items, columns: columns, rowHeight: rowHeight, inset: inset, card: card)
        }
    }
}

// MARK: - card foot

/// The foot of a card: its controls on one line when they fit, else one under another. Nothing runs out of the card in a
/// narrow column or with a long translation.
struct MarketFootRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FirstFit(count: 2) { index, _ in
            if index == 0 {
                HStack(spacing: 8) { content }
            } else {
                VStack(alignment: .leading, spacing: 6) { content }
            }
        }
    }
}

extension View {
    /// A card that opens its page when clicked: the whole surface is the target, and VoiceOver gets the same action.
    func marketCardOpens(_ label: String, perform action: @escaping () -> Void) -> some View {
        contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture(perform: action)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
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

