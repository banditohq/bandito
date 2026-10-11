import AppKit
import BanditoDesign
import BanditoL10n
import Observation
import SwiftUI

// The showcase of the Marketplace: a shelf is a header ("symbol, name, number, All") over one row of cards that scrolls
// sideways and snaps to a card; a category's page is a header with Back over a grid. Services, Bots and Skills use the
// same parts.

// MARK: - header

/// The header of a shelf: the category's symbol, its name in the display face, the number of cards, and at the right
/// (an optional control and) "All", which opens the page of everything the shelf holds. No colour, no band: the header is
/// quiet type on the page's ground.
struct MarketShelfHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    let count: Int
    var onAll: (() -> Void)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(BanditoFont.display(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(count)")
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            accessory
            if let onAll {
                Button(action: onAll) {
                    HStack(spacing: 3) {
                        Text(L10n.Market.Shelf.all)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
                    .fixedSize()
                }
                .banditoButton(.link)
                .accessibilityLabel(L10n.Market.Shelf.allLabel(name: title))
            }
        }
        .padding(.horizontal, MarketGridLayout.sidePadding)
        .frame(height: MarketShelfMetrics.headerHeight)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension MarketShelfHeader where Accessory == EmptyView {
    init(title: String, symbol: String, count: Int, onAll: (() -> Void)?) {
        self.init(title: title, symbol: symbol, count: count, onAll: onAll) { EmptyView() }
    }
}

// MARK: - shelf

/// A shelf: its header and its row of cards. Every card has the shelf's height and the shelf's width.
struct MarketShelfView<Item: Identifiable, Card: View, Accessory: View>: View {
    let title: String
    let symbol: String
    let count: Int
    let items: [Item]
    let cardHeight: CGFloat
    var onAll: (() -> Void)?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        let _ = PerfCounters.hit("MarketShelf")
        VStack(alignment: .leading, spacing: MarketShelfMetrics.headerGap) {
            MarketShelfHeader(title: title, symbol: symbol, count: count, onAll: onAll) { accessory }
            MarketShelfLane(items: items, cardHeight: cardHeight, card: card)
        }
    }
}

extension MarketShelfView where Accessory == EmptyView {
    init(
        title: String, symbol: String, count: Int, items: [Item], cardHeight: CGFloat, onAll: (() -> Void)?,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.init(
            title: title, symbol: symbol, count: count, items: items, cardHeight: cardHeight, onAll: onAll,
            accessory: { EmptyView() }, card: card)
    }
}

/// The row of cards. It is lazy sideways: only the cards near the window are built. It snaps to a card (`viewAligned`),
/// has the page margin as a content margin (so the cards pass under the edge of the window, not under the margin), and
/// the two arrows of `MarketShelfArrows`.
struct MarketShelfLane<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let cardHeight: CGFloat
    @ViewBuilder var card: (Item) -> Card

    /// Where the row is. The lane never reads it: only the arrows do, so a change of it redraws them and not the cards.
    @State private var scroll = MarketShelfScrollModel()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MarketShelfMetrics.gap) {
                    ForEach(items) { item in
                        card(item)
                            .frame(width: MarketShelfMetrics.cardWidth, height: cardHeight)
                    }
                }
                .scrollTargetLayout()
                .padding(.top, MarketShelfMetrics.laneTop)
                .padding(.bottom, MarketShelfMetrics.laneBottom)
                .background { MarketShelfScrollObserver(model: scroll) }
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, MarketGridLayout.sidePadding, for: .scrollContent)
            .frame(height: MarketShelfMetrics.laneHeight(card: cardHeight))
            .modifier(MarketShelfArrows(ids: items.map(\.id), proxy: proxy, model: scroll))
        }
    }
}

// MARK: - arrows

/// Where a shelf's row is, for its arrows. `scroll` is rewritten at every scroll step but nothing observes it; the two
/// flags are written only when they change, and they are what the arrows watch.
@MainActor
@Observable
final class MarketShelfScrollModel {
    private(set) var canBack = false
    private(set) var canForward = false
    @ObservationIgnored private(set) var scroll = MarketShelfScroll()

    func update(_ new: MarketShelfScroll) {
        scroll = new
        if canBack != new.canBack { canBack = new.canBack }
        if canForward != new.canForward { canForward = new.canForward }
    }
}

/// Reports the place of the row to a `MarketShelfScrollModel`. SwiftUI's scroll geometry callback needs macOS 15; the app
/// runs on 14, so this watches the scroll view that holds it (an `NSScrollView`) for the movement of its clip view and
/// for a change in the size of its content. It sits in the row's content, which is how it finds the scroll view.
struct MarketShelfScrollObserver: NSViewRepresentable {
    let model: MarketShelfScrollModel

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.model = model
    }

    final class ObserverView: NSView {
        weak var model: MarketShelfScrollModel?
        private weak var scrollView: NSScrollView?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                detach()
                return
            }
            // The scroll view is above this view once it is in a window.
            attach()
        }

        private func attach() {
            var parent = superview
            while let view = parent, !(view is NSScrollView) { parent = view.superview }
            guard let found = parent as? NSScrollView, found !== scrollView else { return }
            detach()
            scrollView = found
            let clip = found.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            var watched: [(NSView, Notification.Name)] = [
                (clip, NSView.boundsDidChangeNotification), (clip, NSView.frameDidChangeNotification),
            ]
            if let document = found.documentView {
                document.postsFrameChangedNotifications = true
                watched.append((document, NSView.frameDidChangeNotification))
            }
            tokens = watched.map { view, name in
                NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func detach() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
            scrollView = nil
        }

        private func report() {
            guard let scroll = scrollView, let model else { return }
            let clip = scroll.contentView
            model.update(
                MarketShelfScroll(
                    offset: clip.bounds.origin.x, container: clip.bounds.width,
                    content: scroll.documentView?.frame.width ?? 0, leadingInset: scroll.contentInsets.left,
                    trailingInset: scroll.contentInsets.right))
        }
    }
}

/// The two arrows at the edges of a shelf. They show while the pointer is over the shelf, and only on the side where
/// there is more to see. A press scrolls by one screenful of whole cards. Hover is the only state of its own, written
/// when it changes; the edge flags come from the model, which writes them when they change, never at a scroll step.
struct MarketShelfArrows<ID: Hashable>: ViewModifier {
    let ids: [ID]
    let proxy: ScrollViewProxy
    let model: MarketShelfScrollModel

    @State private var hovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    func body(content: Content) -> some View {
        let _ = PerfCounters.hit("MarketShelfArrows")
        content
            .onHover { inside in
                if hovering != inside { hovering = inside }
            }
            // VoiceOver and the keyboard reach the same two moves without the pointer.
            .accessibilityAction(named: Text(L10n.Market.Shelf.previous)) { page(forward: false) }
            .accessibilityAction(named: Text(L10n.Market.Shelf.next)) { page(forward: true) }
            #if DEBUG
            .onAppear { MarketShelfDebug.register(model, page: { page(forward: $0) }) }
            .onDisappear { MarketShelfDebug.unregister(model) }
            #endif
            .overlay(alignment: .leading) { arrow(forward: false, visible: hovering && model.canBack) }
            .overlay(alignment: .trailing) { arrow(forward: true, visible: hovering && model.canForward) }
    }

    private func arrow(forward: Bool, visible: Bool) -> some View {
        Button {
            page(forward: forward)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.Bandito.surface3))
                .overlay(Circle().strokeBorder(Color.Bandito.text.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(visible ? 0.35 : 0), radius: 6, y: 3)
        }
        .banditoButton(.brighten)
        .accessibilityLabel(forward ? L10n.Market.Shelf.next : L10n.Market.Shelf.previous)
        .help(forward ? L10n.Market.Shelf.next : L10n.Market.Shelf.previous)
        .padding(.horizontal, 8)
        // The lane has more room under the cards (for a shadow) than above them: the arrow sits at the cards' middle.
        .offset(y: -(MarketShelfMetrics.laneBottom - MarketShelfMetrics.laneTop) / 2)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: visible)
    }

    private func page(forward: Bool) {
        guard let index = model.scroll.pageIndex(forward: forward, count: ids.count) else { return }
        let id = ids[index]
        let level = MotionLevel(stored: motionLevel)
        if level.reducesMotion(systemReduceMotion: reduceMotion) {
            proxy.scrollTo(id, anchor: .leading)
        } else {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: level.scaled(0.4))) {
                proxy.scrollTo(id, anchor: .leading)
            }
        }
    }
}

// MARK: - page

/// The header of a page that lists one thing in full: Back, then the name with its symbol and the number of cards.
struct MarketPageHeader: View {
    let title: String
    let symbol: String
    let count: Int
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.Common.back)
                }
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .fixedSize()
            }
            .banditoButton(.link)
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
                    .accessibilityHidden(true)
                Text(title)
                    .font(BanditoFont.display(size: 20, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("\(count)")
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, MarketGridLayout.sidePadding)
    }
}

/// The title of a part of a page that has several (the sets above the bots of a category).
struct MarketPartLabel: View {
    let text: String

    var body: some View {
        SectionLabel(text)
            .padding(.horizontal, MarketGridLayout.sidePadding)
            .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
/// QA: the shelves that are on screen, so `shelf next|back [n]` can press an arrow without a pointer (see `QAHooks`).
@MainActor
enum MarketShelfDebug {
    private static var pagers: [(ObjectIdentifier, (Bool) -> Void)] = []

    static func register(_ model: MarketShelfScrollModel, page: @escaping (Bool) -> Void) {
        let id = ObjectIdentifier(model)
        pagers.removeAll { $0.0 == id }
        pagers.append((id, page))
    }

    static func unregister(_ model: MarketShelfScrollModel) {
        let id = ObjectIdentifier(model)
        pagers.removeAll { $0.0 == id }
    }

    static func press(forward: Bool, index: Int) {
        guard pagers.indices.contains(index) else {
            NSLog("QA: no shelf \(index) of \(pagers.count)")
            return
        }
        pagers[index].1(forward)
    }
}
#endif
