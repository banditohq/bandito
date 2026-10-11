import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// The cards of the Services page. They are `Equatable` on what they draw (not on their closures), so a change of one
// service, a check result or a hover redraws one card and not the grid.

/// What a card can ask the page to do. Built once per page body; the cards ignore it when they compare.
struct MarketCardActions {
    var open: (MarketEntry) -> Void
    var connect: (IntegrationCatalogEntry) -> Void
    var configure: (Integration) -> Void
    var check: (Integration) -> Void
    var remove: (Integration) -> Void
    var signInAgain: (Integration) -> Void
    var setEnabled: (Integration, Bool) -> Void
    var update: (Integration) -> Void
}

// MARK: - catalog card

/// A service of the catalog, or a connected one in a flat list: the tile, the name and the publisher, the description
/// (three lines, then an ellipsis), and the actions at the bottom. The card has a fixed height, so a row is even. When
/// the two actions do not fit side by side (a narrow column, a long translation), they stack.
struct MarketCatalogCard: View, Equatable {
    let entry: MarketEntry
    let actions: MarketCardActions

    nonisolated static func == (lhs: MarketCatalogCard, rhs: MarketCatalogCard) -> Bool { lhs.entry == rhs.entry }

    var body: some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    MarketTile(entry: entry, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let publisher = entry.template?.publisher {
                            Text(publisher)
                                .font(BanditoFont.text(size: 11, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.description)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                actionRow
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onTapGesture { actions.open(entry) }
    }

    private var viewButton: some View {
        Button(L10n.Market.view) { actions.open(entry) }
            .banditoButton(.quiet())
            .fixedSize()
    }

    /// View and the rest on one line when they fit, else the rest under View.
    private var actionRow: some View {
        MarketActionRow {
            viewButton
        } trailing: {
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let integration = entry.integration {
            Label {
                Text(L10n.Integrations.Oauth.connected)
            } icon: {
                Image(systemName: "checkmark")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
            .lineLimit(1)
            .fixedSize()
            if !integration.auth.isDaemonSignIn {
                Button(L10n.Market.configure) { actions.configure(integration) }
                    .banditoButton(.link)
                    .fixedSize()
            }
        } else if let template = entry.template {
            Button(L10n.Integrations.connect) { actions.connect(template) }
                .banditoButton(.lightPill())
                .fixedSize()
        }
    }
}

// MARK: - connected card

/// A connected service: its address, the last check, how much it was used, the update line, and the switch that turns
/// it on or off for the agents; the menu has check, edit and remove.
struct MarketConnectedCard: View, Equatable {
    let entry: MarketEntry
    let integration: Integration
    let status: IntegrationStatus
    /// "12 calls today" and the like; nil when there is nothing to say.
    let statsLine: String?
    /// An update from the template is running.
    let updating: Bool
    /// A check is running.
    let checking: Bool
    let actions: MarketCardActions

    nonisolated static func == (lhs: MarketConnectedCard, rhs: MarketConnectedCard) -> Bool {
        lhs.entry == rhs.entry && lhs.status == rhs.status && lhs.statsLine == rhs.statsLine
            && lhs.updating == rhs.updating && lhs.checking == rhs.checking
    }

    var body: some View {
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    MarketTile(entry: entry, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(MarketLogic.address(integration))
                            .font(BanditoFont.mono(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    menu
                }
                IntegrationStatusLine(status: status)
                if let statsLine {
                    Text(statsLine)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
                if let update = integration.templateUpdate {
                    updateLine(update)
                }
                if status == .needsLogin {
                    Button(L10n.Integrations.Oauth.signInAgain) { actions.signInAgain(integration) }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { integration.enabled }, set: { on in actions.setEnabled(integration, on) })) {
                    Text(L10n.Market.availableToAgents)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(BanditoToggleStyle())
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onTapGesture { actions.open(entry) }
    }

    /// "Update available · 1.2 → 1.3" and Update: the catalog's definition of this service moved on.
    private func updateLine(_ update: TemplateUpdate) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(UpdateLine(update).text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(BanditoFont.text(size: 12, weight: 500))
            .foregroundStyle(Color.Bandito.info)
            Spacer(minLength: 4)
            Button(updating ? L10n.Market.Update.updating : L10n.Market.Update.button) {
                actions.update(integration)
            }
            .banditoButton(.quiet())
            .disabled(updating)
            .fixedSize()
        }
    }

    private var menu: some View {
        Menu {
            Button(checking ? L10n.Integrations.checking : L10n.Integrations.check) {
                actions.check(integration)
            }
            .disabled(checking || !integration.enabled)
            if integration.auth.isDaemonSignIn {
                Button(L10n.Integrations.Oauth.signInAgain) { actions.signInAgain(integration) }
            } else {
                Button(L10n.Integrations.edit) { actions.configure(integration) }
            }
            Divider()
            Button(L10n.Integrations.remove, role: .destructive) { actions.remove(integration) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .banditoButton(.icon(size: 26, label: L10n.Market.more))
        .fixedSize()
    }
}
