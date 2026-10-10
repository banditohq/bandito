import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The size of the picture in the card. Pure, so the rule is easy to read and test.
enum BrowserRunPreview {
    /// The picture's height in the card, in points. It is the same for every page, so the card's height does not
    /// change when the page changes shape.
    static let pictureHeight: CGFloat = 200

    /// The picture's height in a card `width` wide: always `pictureHeight`, or 0 when the width is not a usable number.
    static func height(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return pictureHeight
    }

    /// What the picture area shows: the live picture, the wait for the first picture of a running browser, the last
    /// picture of a closed browser, or the word that the browser is closed.
    enum Picture: Equatable {
        case live, waiting, lastFrame, closed
    }

    /// `running` is nil until the browser's status is known: the card waits then, as it does while the browser starts.
    static func picture(hasFrame: Bool, running: Bool?, hasLastFrame: Bool) -> Picture {
        if hasFrame { return .live }
        guard running == false else { return .waiting }
        return hasLastFrame ? .lastFrame : .closed
    }
}

/// Gives its content the card's full width and the height `BrowserRunPreview.height(width:)` says.
private struct BrowserRunPreviewLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: BrowserRunPreview.height(width: width))
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
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            if tools.contains(where: { $0.ok == nil }) {
                StatusDot(status: .working)
            }
        }
    }

    /// The picture fills the card's width, 200 pt tall, cropped from the bottom so the top of the page shows (as
    /// `.aspectRatio(.fill)` with top alignment). It sits in a thin frame. It is drawn in a layer that the browser
    /// model feeds directly: the card does not redraw per frame.
    private func preview(_ model: BrowserModel) -> some View {
        BrowserRunPreviewLayout {
            ZStack {
                Color.Bandito.surface1
                switch BrowserRunPreview.picture(
                    hasFrame: model.hasFrame, running: model.status?.running, hasLastFrame: model.hasLastFrame)
                {
                case .live:
                    BrowserFrameLayer(store: model.frames, fillsFromTop: true)
                        .accessibilityHidden(true)
                case .lastFrame:
                    BrowserFrameLayer(store: model.lastFrames, fillsFromTop: true)
                        .accessibilityHidden(true)
                case .waiting:
                    placeholder(L10n.Thread.BrowserRun.noPicture)
                case .closed:
                    placeholder(L10n.Thread.BrowserRun.closed)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Bandito.line, lineWidth: 0.5))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .multilineTextAlignment(.center)
            .padding(12)
    }

    /// One line: the page's icon, title and domain on the left, the two buttons on the right.
    private func footer(_ model: BrowserModel) -> some View {
        let label = BrowserTabLabel.make(title: model.pageTitle, url: model.currentURL, newTabTitle: L10n.Browser.newTab)
        return HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            Text(label.title)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
                // The title keeps its room: the buttons give way before it does.
                .frame(minWidth: 120, alignment: .leading)
                .layoutPriority(1)
            if !label.domain.isEmpty, label.domain != label.title {
                Text(label.domain)
                    .font(BanditoFont.text(size: 12, weight: 400))
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
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .banditoButton(.quiet())
            .help(L10n.Thread.BrowserRun.fullscreen)
            .accessibilityLabel(L10n.Thread.BrowserRun.fullscreen)
        }
    }
}
