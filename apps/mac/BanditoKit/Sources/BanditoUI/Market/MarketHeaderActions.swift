import BanditoDesign
import BanditoL10n
import SwiftUI

/// The search field and the actions of the Marketplace header: import from Claude Code, own integration, my shares.
/// Three forms, the first that fits the width: text buttons; icon buttons with tooltips; one "…" menu with the same
/// actions. The header never asks for more width than the window has, so the page keeps its width.
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

    private enum Form {
        case text, icons, menu
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.text)
            row(.icons)
            row(.menu)
        }
    }

    private func row(_ form: Form) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if showsSearch {
                search
            }
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
