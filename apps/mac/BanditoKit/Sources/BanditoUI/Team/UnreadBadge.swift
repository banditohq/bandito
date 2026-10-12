import BanditoDesign
import BanditoL10n
import SwiftUI

/// The unread replies of an agent: a capsule in the accent (cream, the primary's colour), "99+" above 99. Nothing for 0.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if let text = UnreadRules.badge(count) {
            Text(text)
                .font(BanditoFont.text(size: 10.5, weight: 600))
                .monospacedDigit()
                .foregroundStyle(Color.Bandito.bg)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(minWidth: 18, minHeight: 16)
                .background(Color.Bandito.text, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.Sidebar.unread(count: count))
        }
    }
}

/// The unread mark on a round avatar (a pinned agent): a small dot, the same colour as the count. Nothing for 0.
struct UnreadDot: View {
    let count: Int
    var ring: Color

    var body: some View {
        if count > 0 {
            Circle()
                .fill(Color.Bandito.text)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(ring, lineWidth: 2))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.Sidebar.unread(count: count))
        }
    }
}
