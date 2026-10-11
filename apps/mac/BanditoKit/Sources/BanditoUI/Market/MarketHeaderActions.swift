import BanditoDesign
import BanditoL10n
import SwiftUI

/// The search field and the actions of the Marketplace header: import from Claude Code, own integration, my shares.
/// Three forms, the first that fits the width: text buttons; icon buttons with tooltips; one "…" menu with the same
/// actions. The header never asks for more width than the window has, so the page keeps its width.
///
/// Not a `ViewThatFits`: it measured its three rows again at every layout of the window, about 200 ms at each category
/// page, search letter or tab of the Marketplace. The rows are measured once, out of sight, at their own width; the
/// choice is made from those widths and the width the header gives (`MarketHeaderFit`).
struct MarketHeaderActions<Search: View>: View {
    /// The search field, shown when `showsSearch`.
    let showsSearch: Bool
    let search: Search
    /// Import and own integration, shown when `addsIntegration`. My shares, shown when `showsMine`.
    let addsIntegration: Bool
    let showsMine: Bool
    let onImport: () -> Void
    let onOwn: () -> Void
    let onMine: () -> Void
    /// The width the field and the actions may take; nil while not known.
    var available: CGFloat?

    /// The width of each form of the actions, as measured.
    @State private var widths: [MarketHeaderFit.Form: CGFloat] = [:]

    var body: some View {
        HStack(alignment: .center, spacing: MarketHeaderFit.spacing) {
            if showsSearch {
                search
            }
            row(MarketHeaderFit.form(available: available, widths: widths, search: showsSearch))
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(MarketHeaderFit.Form.allCases, id: \.self) { form in
                    row(form)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if widths[form] != width { widths[form] = width }
                        }
                }
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func row(_ form: MarketHeaderFit.Form) -> some View {
        HStack(alignment: .center, spacing: MarketHeaderFit.spacing) {
            switch form {
            case .text: textButtons
            case .icons: iconButtons
            case .menu: menuButton
            }
        }
    }

    @ViewBuilder
    private var textButtons: some View {
        if addsIntegration {
            Button(L10n.ClaudeImport.title, action: onImport)
                .banditoButton(.quiet())
                .fixedSize()
            Button(L10n.Integrations.addOwn, action: onOwn)
                .banditoButton(.quiet())
                .fixedSize()
        }
        if showsMine {
            Button(L10n.Share.Mine.title, action: onMine)
                .banditoButton(.quiet())
                .fixedSize()
        }
    }

    @ViewBuilder
    private var iconButtons: some View {
        if addsIntegration {
            iconButton("square.and.arrow.down", L10n.ClaudeImport.title, onImport)
            iconButton("plus", L10n.Integrations.addOwn, onOwn)
        }
        if showsMine {
            iconButton("link", L10n.Share.Mine.title, onMine)
        }
    }

    private func iconButton(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
        }
        .banditoButton(.icon(size: 32, label: title))
        .help(title)
    }

    private var menuButton: some View {
        Menu {
            if addsIntegration {
                Button(L10n.ClaudeImport.title, action: onImport)
                Button(L10n.Integrations.addOwn, action: onOwn)
            }
            if showsMine {
                Button(L10n.Share.Mine.title, action: onMine)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .banditoButton(.icon(size: 32, label: L10n.Market.more))
        .help(L10n.Market.more)
    }
}

/// Which form of the Marketplace header's actions fits a width.
enum MarketHeaderFit {
    enum Form: CaseIterable, Hashable {
        case text, icons, menu
    }

    /// The space between the field and the actions, and between two actions.
    static let spacing: CGFloat = 10

    /// The first form whose measured width, with the search field before it, fits `available`; the menu when nothing
    /// else fits, and until the width and the forms are measured (the most compact never runs over the edge).
    static func form(available: CGFloat?, widths: [Form: CGFloat], search: Bool) -> Form {
        guard let available, widths.count == Form.allCases.count else { return .menu }
        let field = search ? MarketSearchField.width + spacing : 0
        for form in [Form.text, .icons] where field + (widths[form] ?? .infinity) <= available + 0.5 {
            return form
        }
        return .menu
    }
}
