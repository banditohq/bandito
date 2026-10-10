import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// A mention as a pill: the picture of what it names (a service's logo, an agent's avatar, a file's glyph, the
/// browser mark) and its label. In a message it sits under the bubble; in the composer it has a cross.
struct MentionChip: View {
    var mention: Mention
    var market: MarketEntry?
    var server: ServerModel?
    /// A service that is not connected yet: the pill is dashed.
    var pending = false
    /// The cross of the composer's chip; `nil` in a message.
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            MentionIcon(mention: mention, market: market, server: server, size: 18)
            Text(mention.label)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .banditoButton(.icon(size: 18, label: L10n.Composer.Attach.remove))
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, onRemove == nil ? 10 : 3)
        .frame(height: 26)
        .frame(maxWidth: 260)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.Bandito.surface3, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                pending ? BanditoPalette.peach.opacity(0.6) : Color.Bandito.line,
                style: StrokeStyle(lineWidth: pending ? 1 : 0.5, dash: pending ? [3, 2] : []))
        )
        .accessibilityElement(children: .combine)
    }
}

/// The mentions of a message in the thread, under the bubble and to the right, wrapping when they do not fit. A
/// service wears the logo the Marketplace shows; a file opens in the workbench beside the chat.
struct MessageMentions: View {
    var mentions: [Mention]
    var agentID: String
    var server: ServerModel

    @Environment(Router.self) private var router: Router?

    var body: some View {
        let services = MentionServices.shared
        let snapshot = services.snapshot(for: server)
        TrailingChips {
            ForEach(mentions) { mention in
                chip(mention, snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .task(id: mentions.contains { $0.kind == .integration }) {
            if mentions.contains(where: { $0.kind == .integration }) { await services.ensure(server) }
        }
    }

    @ViewBuilder
    private func chip(_ mention: Mention, snapshot: MentionServices.Snapshot?) -> some View {
        let market = snapshot.flatMap {
            MentionServices.market(
                for: mention, catalog: $0.catalog, integrations: $0.integrations,
                languageCode: ModelDescription.currentLanguageCode)
        }
        if mention.kind == .file, let router {
            Button {
                router.showInWorkbench(.file(path: mention.id), agentID: agentID)
            } label: {
                MentionChip(mention: mention, market: market, server: server)
            }
            .buttonStyle(.plain)
            .help(mention.id)
        } else {
            MentionChip(mention: mention, market: market, server: server)
        }
    }
}

/// The strip of the composer's chips above the field.
struct MentionStrip: View {
    var items: [DraftMention]
    var server: ServerModel?
    var onRemove: (DraftMention) -> Void

    var body: some View {
        let snapshot = server.flatMap { MentionServices.shared.snapshot(for: $0) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.mention.id) { item in
                    MentionChip(
                        mention: item.mention,
                        market: snapshot.flatMap {
                            MentionServices.market(
                                for: item.mention, catalog: $0.catalog, integrations: $0.integrations,
                                languageCode: ModelDescription.currentLanguageCode)
                        },
                        server: server, pending: item.pendingTemplate != nil,
                        onRemove: { onRemove(item) })
                }
            }
            .padding(.trailing, 6)
        }
    }
}

/// Places its children in rows against the right edge, and starts a new row when the width runs out.
struct TrailingChips: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows.map { $0.map { (index: $0.0, size: $0.1) } }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let laid = rows(subviews, width: width)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for row in laid {
            height += rowHeight(row)
            widest = max(widest, rowWidth(row))
        }
        height += spacing * CGFloat(max(laid.count - 1, 0))
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    // Spelled out with explicit types: the one-line version took the type checker too long on CI.
    private func rowWidth(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
        var total: CGFloat = 0
        for item in row { total += item.size.width }
        return total + spacing * CGFloat(max(row.count - 1, 0))
    }

    private func rowHeight(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
        var tallest: CGFloat = 0
        for item in row { tallest = max(tallest, item.size.height) }
        return tallest
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - rowWidth(row)
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight(row) + spacing
        }
    }
}
