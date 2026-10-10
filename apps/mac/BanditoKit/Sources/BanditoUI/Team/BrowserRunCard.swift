import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The size of the picture in the card. Pure, so the rules are easy to read and test.
enum BrowserRunPreview {
    /// The tallest the picture gets, in points.
    static let maxHeight: CGFloat = 220
    /// The ratio shown before the first frame.
    static let placeholderAspect: CGFloat = 1.6

    /// Width over height of the page, kept in a sane range so an odd page size never makes a sliver. The placeholder
    /// ratio for a size that is not known yet.
    static func aspect(of page: CGSize) -> CGFloat {
        guard page.width.isFinite, page.height.isFinite, page.width >= 1, page.height >= 1 else { return placeholderAspect }
        return min(max(page.width / page.height, 0.4), 3)
    }

    /// The height of the picture in a card `width` wide: the width at the page's ratio, at most `maxHeight`.
    static func height(width: CGFloat, aspect: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, aspect > 0 else { return 0 }
        return min(maxHeight, (width / aspect).rounded())
    }
}

/// Gives its content the card's full width and the height `BrowserRunPreview.height` says.
private struct BrowserRunPreviewLayout: Layout {
    var aspect: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: BrowserRunPreview.height(width: width, aspect: aspect))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// The browser calls of the agent in a row, as one live card: "Agent in the browser", a picture of the page that
/// follows the browser while the card is on screen, the page's title and domain, and two buttons: watch it beside
/// the chat, or open the Browser mode.
struct BrowserRunCard: View {
    var tools: [ToolRow]
    var server: ServerModel
    var agentID: String

    /// Optional, like the thread's: without a router the buttons do nothing.
    @Environment(Router.self) private var router: Router?

    var body: some View {
        let model = BrowserStore.shared.model(for: server)
        VStack(alignment: .leading, spacing: 10) {
            header
            preview(model)
            footer(model)
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

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.Thread.BrowserRun.title)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            if tools.contains(where: { $0.ok == nil }) {
                StatusDot(status: .working)
            }
        }
    }

    /// The picture fills the card's width at the page's ratio (at most 220 pt tall), on the card's surface, with no bars.
    /// It is drawn in a layer that the browser model feeds directly: the card does not redraw per frame.
    private func preview(_ model: BrowserModel) -> some View {
        BrowserRunPreviewLayout(aspect: BrowserRunPreview.aspect(of: model.hasFrame ? model.pageSize : .zero)) {
            ZStack {
                Color.Bandito.surface1
                if model.hasFrame {
                    BrowserFrameLayer(store: model.frames)
                        .accessibilityHidden(true)
                } else {
                    Text(L10n.Thread.BrowserRun.noPicture)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .multilineTextAlignment(.center)
                        .padding(12)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// One line: the page's icon, title and domain on the left, the two buttons on the right.
    private func footer(_ model: BrowserModel) -> some View {
        let label = BrowserTabLabel.make(title: model.pageTitle, url: model.currentURL, newTabTitle: L10n.Browser.newTab)
        return HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            Text(label.title)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if !label.domain.isEmpty, label.domain != label.title {
                Text(label.domain)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Button {
                router?.showInWorkbench(.browser, agentID: agentID)
            } label: {
                Text(L10n.Thread.BrowserRun.watchBeside)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .banditoButton(.lightPill(size: .regular))
            Button {
                router?.select(mode: .browser)
            } label: {
                Text(L10n.Thread.BrowserRun.fullscreen)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .banditoButton(.lightPill(size: .regular))
        }
    }
}
