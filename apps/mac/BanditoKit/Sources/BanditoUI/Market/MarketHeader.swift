import BanditoDesign
import BanditoL10n
import SwiftUI

/// The search text of the Marketplace, in a reference: the field writes it and the page reads it; the header holds the
/// reference only, so a letter typed does not rebuild the header.
@MainActor
@Observable
final class MarketSearch {
    var text = ""
}

/// The head of the Marketplace: the title and the page's line, the pages (Services, Bots, Skills), the search and the
/// actions. Equal when what it shows is equal: the actions are closures that stay right for the page, so a change of
/// the page under the header (a category, a search letter) does not build and measure the header again.
struct MarketHeader: View, Equatable {
    let tab: MarketTab
    let tabs: [MarketTab]
    let supported: Bool
    let sharingSupported: Bool
    let search: MarketSearch
    let onTab: (MarketTab) -> Void
    let onImport: () -> Void
    let onOwn: () -> Void
    let onMine: () -> Void

    /// The header's width, and the widths of the parts beside the actions: what the actions may take follows.
    @State private var width: CGFloat?
    @State private var titleWidth: CGFloat?
    @State private var pickerWidth: CGFloat?

    nonisolated static func == (lhs: MarketHeader, rhs: MarketHeader) -> Bool {
        lhs.tab == rhs.tab && lhs.tabs == rhs.tabs && lhs.supported == rhs.supported
            && lhs.sharingSupported == rhs.sharingSupported && lhs.search === rhs.search
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            if width != new { width = new }
        }
    }

    @ViewBuilder
    private var content: some View {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Mode.market)
                        .font(BanditoFont.display(size: 24, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        // Unbounded is wide: in a narrow window the title shrinks instead of breaking inside the word.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .background {
                    // The title at its own width: the actions beside it take what it leaves.
                    Text(L10n.Mode.market)
                        .font(BanditoFont.display(size: 24, weight: 600))
                        .fixedSize()
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                            if titleWidth != new { titleWidth = new }
                        }
                }
                Spacer(minLength: 12)
                if tabs.count == 1, supported {
                    // A server with only services keeps the one-row header.
                    actions(showsSearch: true, addsIntegration: true, beside: titleWidth.map { $0 + 14 + 12 + 14 })
                }
            }
            if tabs.count > 1 {
                HStack(alignment: .center, spacing: 12) {
                    SegmentedPicker(
                        selection: Binding(get: { tab }, set: { onTab($0) }),
                        options: tabs.map { ($0, $0.title) }
                    )
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                        if pickerWidth != new { pickerWidth = new }
                    }
                    Spacer(minLength: 12)
                    actions(
                        showsSearch: tab != .services || supported, addsIntegration: tab == .services && supported,
                        beside: pickerWidth.map { $0 + 12 + 12 + 12 })
                }
            }
    }

    /// The search field and the actions of the header: text buttons, icon buttons or one menu, whichever fits in what
    /// the parts `beside` them leave (nil until those are measured).
    private func actions(showsSearch: Bool, addsIntegration: Bool, beside: CGFloat?) -> some View {
        MarketHeaderActions(
            showsSearch: showsSearch,
            search: MarketSearchField(search: search),
            addsIntegration: addsIntegration,
            showsMine: sharingSupported,
            onImport: onImport,
            onOwn: onOwn,
            onMine: onMine,
            available: width.flatMap { width in beside.map { width - $0 } })
    }

    private var subtitle: String {
        switch tab {
        case .services: L10n.Market.subtitle
        case .bots: L10n.Market.Bots.subtitle
        case .skills: L10n.Market.Skills.subtitle
        }
    }
}

/// One capsule holds the lens and the field: the capsule draws the fill and the border, the field inside is plain.
/// Focus shows as a cream ring on the capsule. It reads and writes the search text itself.
struct MarketSearchField: View {
    /// The field's width (`MarketHeaderFit` counts it).
    static let width: CGFloat = 240

    @Bindable var search: MarketSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.Market.search, text: $search.text)
                .textFieldStyle(.plain)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .focused($focused)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: 32)
        .background(Capsule().fill(Color.Bandito.text.opacity(0.05)))
        .overlay(Capsule().strokeBorder(focused ? Color.Bandito.text.opacity(0.3) : Color.Bandito.line, lineWidth: 1))
        .banditoAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: BanditoMotion.fast), value: focused)
    }
}
