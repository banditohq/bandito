import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The host of a page address for the card's title: `shop.example` for `https://www.shop.example/cart`. `nil` for
/// an address without a host (`about:blank`, an empty page).
enum BrowserRunDomain {
    static func host(of address: String) -> String? {
        guard let host = URL(string: address)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The browser calls of the agent in a row, as one live card: "Agent in the browser · shop.example", a small
/// picture of the page that updates twice a second while the card is on screen, and two buttons: watch it beside
/// the chat, or open the Browser mode.
struct BrowserRunCard: View {
    var tools: [ToolRow]
    var server: ServerModel
    var agentID: String

    /// Optional, like the thread's: without a router the buttons do nothing.
    @Environment(Router.self) private var router: Router?

    /// How often the picture is taken from the browser model. Twice a second is enough for a preview.
    static let refreshInterval: TimeInterval = 0.5

    var body: some View {
        let model = BrowserStore.shared.model(for: server)
        VStack(alignment: .leading, spacing: 10) {
            header(domain: BrowserRunDomain.host(of: model.currentURL))
            preview(model)
            HStack(spacing: 8) {
                Button {
                    router?.showInWorkbench(.browser, agentID: agentID)
                } label: {
                    Text(L10n.Thread.BrowserRun.watchBeside)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.quiet())
                Button {
                    router?.select(mode: .browser)
                } label: {
                    Text(L10n.Thread.BrowserRun.openBrowser)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.quiet())
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Bandito.line, lineWidth: 0.5))
        // The browser is polled and its page connection kept only while this card is on screen. Attach and detach
        // are paired on appear and disappear, so the count the browser keeps stays balanced.
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }

    private func header(domain: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            Text(domain.map { L10n.Thread.BrowserRun.titleDomain(domain: $0) } ?? L10n.Thread.BrowserRun.title)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if tools.contains(where: { $0.ok == nil }) {
                StatusDot(status: .working)
            }
        }
    }

    /// The last picture of the page, or a quiet placeholder while there is none. The timeline samples the model
    /// every `refreshInterval`, so the picture follows the browser without a change notification per frame.
    private func preview(_ model: BrowserModel) -> some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            Group {
                if let frame = model.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(L10n.Thread.BrowserRun.noPicture)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .multilineTextAlignment(.center)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
