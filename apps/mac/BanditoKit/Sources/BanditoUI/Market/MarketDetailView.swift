import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The page of one service inside the Marketplace: what it is, what it can do, what it needs and how to connect it;
/// and, once connected, its status, its tools and the switches. Everything it shows comes from the catalog entry and
/// from the integration; the actions are the page's owner's.
struct MarketDetailView: View {
    let entry: MarketEntry
    let languageCode: String
    /// The last check of the integration in this session.
    let test: IntegrationTest?
    let checking: Bool
    /// The daemon's word on a browser sign-in, when the integration has one.
    var connection: OAuthConnection?
    var onBack: () -> Void
    var onConnect: () -> Void
    var onSignInAgain: () -> Void
    var onConfigure: () -> Void
    var onCheck: () -> Void
    var onRemove: () -> Void
    var onSetEnabled: (Bool) -> Void

    private var template: IntegrationCatalogEntry? { entry.template }
    /// The service's colour: its brand colour, or the palette colour of an own integration.
    private var accent: Color { MarketTileStyle.color(of: entry) }

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                heroBand
                VStack(alignment: .leading, spacing: 24) {
                    backButton
                    header
                    if let template {
                        about(template)
                    }
                    if let integration = entry.integration {
                        connection(integration)
                    }
                    if let template {
                        links(template)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 30)
            }
        }
        .scrollIndicators(.never)
        .background {
            // Esc goes back to the list.
            Button("", action: onBack)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - hero

    /// A 160 pt band at the top of the page: the service's colour at 22%, fading to nothing at its bottom edge.
    /// It is decoration only and takes no clicks.
    private var heroBand: some View {
        LinearGradient(
            colors: [accent.opacity(0.22), accent.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - header

    private var backButton: some View {
        Button(action: onBack) {
            Label(L10n.Mode.market, systemImage: "chevron.left")
        }
        .banditoButton(.link)
        .fixedSize()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            MarketTile(entry: entry, size: 64, glow: true)
                .background {
                    // A soft blur of the service's colour behind the tile.
                    Circle()
                        .fill(accent.opacity(0.35))
                        .frame(width: 130, height: 130)
                        .blur(radius: 30)
                        .allowsHitTesting(false)
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name)
                    .font(BanditoFont.display(size: 22, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(subtitle)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                    if template?.official == true {
                        officialBadge
                    }
                }
            }
            Spacer(minLength: 12)
            actions
        }
    }

    /// The publisher and the category, or the word for an own integration.
    private var subtitle: String {
        guard let template else { return L10n.Integrations.addOwn }
        return [template.publisher, template.category.map(MarketCategory.title)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var officialBadge: some View {
        Label {
            Text(L10n.Market.official)
        } icon: {
            Image(systemName: "checkmark.seal.fill")
        }
        .font(BanditoFont.text(size: 11, weight: 500))
        .foregroundStyle(Color.Bandito.info)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.Bandito.info.opacity(0.12)))
        .fixedSize()
    }

    @ViewBuilder
    private var actions: some View {
        if let integration = entry.integration {
            HStack(spacing: 10) {
                if IntegrationStatus.of(integration, test: test, connection: connection) == .needsLogin {
                    Button(L10n.Integrations.Oauth.signInAgain, action: onSignInAgain)
                        .banditoButton(.signal())
                        .fixedSize()
                } else {
                    Label {
                        Text(L10n.Integrations.connected)
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.ok)
                }
                if integration.auth != .oauth {
                    Button(L10n.Market.configure, action: onConfigure)
                        .banditoButton(.quiet())
                        .fixedSize()
                }
            }
        } else if template != nil {
            Button(L10n.Integrations.connect, action: onConnect)
                .banditoButton(.signal())
                .fixedSize()
        }
    }

    // MARK: - about

    @ViewBuilder
    private func about(_ template: IntegrationCatalogEntry) -> some View {
        let abilities = template.abilities(languageCode: languageCode)
        if !abilities.isEmpty {
            section(L10n.Market.Section.abilities) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(abilities.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                            paragraph(item)
                        }
                    }
                }
            }
        }
        section(L10n.Market.Section.about) {
            paragraph(template.longDescription(languageCode: languageCode))
        }
        if let needs = template.needs(languageCode: languageCode) {
            section(L10n.Market.Section.needs) {
                paragraph(needs)
            }
        }
        section(L10n.Market.Section.how) {
            VStack(alignment: .leading, spacing: 9) {
                let steps = MarketLogic.steps(for: template)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(BanditoFont.text(size: 11, weight: 600))
                            .foregroundStyle(Color.Bandito.text2)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.Bandito.text.opacity(0.07)))
                        paragraph(Self.text(step))
                    }
                }
                addressLine(template)
            }
        }
    }

    /// What the template connects to: the address, or the command, so the owner sees what will run.
    @ViewBuilder
    private func addressLine(_ template: IntegrationCatalogEntry) -> some View {
        let text =
            template.kind == .http
            ? (template.url ?? template.urlHint ?? "")
            : ShellWords.join([template.command ?? ""] + template.args)
        if !text.isEmpty {
            Text(text)
                .font(BanditoFont.mono(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
        }
    }

    static func text(_ step: MarketStep) -> String {
        switch step {
        case .getKey: L10n.Market.Step.getKey
        case .fillAddress: L10n.Market.Step.fillAddress
        case .fillPath: L10n.Market.Step.fillPath
        case .connect: L10n.Market.Step.connect
        case .signIn: L10n.Market.Step.signIn
        }
    }

    // MARK: - connection

    private func connection(_ integration: Integration) -> some View {
        let status = IntegrationStatus.of(integration, test: test, connection: connection)
        return section(L10n.Market.Section.connection) {
            VStack(alignment: .leading, spacing: 12) {
                if template == nil {
                    Text(MarketLogic.address(integration))
                        .font(BanditoFont.mono(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .textSelection(.enabled)
                }
                IntegrationStatusLine(status: status)
                if let test, test.ok, !test.tools.isEmpty {
                    Text(L10n.Market.Section.tools)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(test.tools, id: \.self) { tool in
                            Text(tool)
                                .font(BanditoFont.mono(size: 11.5, weight: 400))
                                .foregroundStyle(Color.Bandito.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
                        }
                    }
                }
                Toggle(isOn: Binding(get: { integration.enabled }, set: onSetEnabled)) {
                    Text(L10n.Market.availableToAgents)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
                .toggleStyle(BanditoToggleStyle())
                HStack(spacing: 10) {
                    Button(checking ? L10n.Integrations.checking : L10n.Integrations.check, action: onCheck)
                        .banditoButton(.quiet())
                        .disabled(checking)
                        .fixedSize()
                    Button(L10n.Integrations.remove, action: onRemove)
                        .banditoButton(.quiet())
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - links

    @ViewBuilder
    private func links(_ template: IntegrationCatalogEntry) -> some View {
        let docs = URL(string: template.docsUrl)
        let site = template.homepage.flatMap { URL(string: $0) }
        if docs != nil || site != nil {
            section(L10n.Market.Section.links) {
                HStack(spacing: 18) {
                    if let docs {
                        link(L10n.Market.docs, docs)
                    }
                    if let site {
                        link(L10n.Market.website, site)
                    }
                }
            }
        }
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.right")
        }
        .font(BanditoFont.text(size: 13, weight: 500))
        .foregroundStyle(Color.Bandito.info)
        .fixedSize()
    }

    // MARK: - pieces

    /// A page section: its label and content in one card.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 13.5, weight: 400))
            .foregroundStyle(Color.Bandito.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
