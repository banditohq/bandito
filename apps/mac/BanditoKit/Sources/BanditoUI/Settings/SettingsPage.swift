import BanditoDesign
import SwiftUI

/// The square icon of a settings row or navigation item: an SF Symbol, white, on a colored fill (24 pt, as in System
/// Settings on macOS).
struct SettingsBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: 24, height: 24)
            .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A group of settings: a section label over a card. The rows inside are laid out by `SettingsRow`.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SectionLabel(title)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .banditoCard()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Common frame of a settings section: title, a short line under it, then the content. Groups are 16 pt apart.
struct SettingsPage<Content: View>: View {
    var title: String
    var intro: String?
    /// How many lines the title may take. A page titled with a person's name (a server) allows two.
    var titleLines = 1
    @ViewBuilder var content: Content

    var body: some View {
        // The whole page scrolls, so nothing is cut off at the smallest window size.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(BanditoFont.display(size: 20, weight: 600))
                        .lineLimit(titleLines)
                        .truncationMode(.tail)
                        .foregroundStyle(Color.Bandito.text)
                    if let intro {
                        Text(intro)
                            .font(BanditoFont.text(size: 13.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 22)
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
    }
}

/// One setting: a title and hint on the left, the control on the right. When the control leaves no room for the
/// text, the control goes under the text (full width), so a title never breaks letter by letter.
struct SettingsRow<Control: View>: View {
    var title: String
    var hint: String?
    /// The icon plate at the left of the row, when the row has one.
    var icon: SettingsIcon?
    /// A switch stays at the right whatever the text length: the text wraps beside it. Wide controls (buttons,
    /// selects) go under a long text instead.
    var keepsControlBeside = false
    @ViewBuilder var control: Control

    var body: some View {
        Group {
            if keepsControlBeside {
                HStack(alignment: .center, spacing: 16) {
                    leading
                    control.fixedSize()
                }
            } else {
                // One copy of the text and of the control, beside or under (`SettingsRowLayout`). A `ViewThatFits` of
                // the two arrangements built and measured both, so every row of a page twice (20 ms of a server's page).
                SettingsRowLayout {
                    leading
                    Spacer(minLength: 12)
                    control
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Every row is at least 44 pt high, as in System Settings, so a short row does not look cramped.
        .frame(minHeight: 44)
    }

    /// The icon (when there is one) and the text, side by side.
    private var leading: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                SettingsBadge(symbol: icon.symbol, tint: icon.tint)
            }
            textBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How a `SettingsRow` places its text and its control, as a `ViewThatFits` of two stacks chose and laid them out:
///
///     HStack(alignment: .center, spacing: 16) { text; Spacer(minLength: 12); control }
///     VStack(alignment: .leading, spacing: 10) { text; HStack(spacing: 8) { control; Spacer(minLength: 0) } }
///
/// The first when its ideal width fits the width offered, else the second. Its children are the views of those stacks
/// once: the text, a spacer, the control's views (none, one or more), a spacer. Each arrangement is laid out as its
/// stack lays it out (`StackRow`); the spacer it does not use takes no room.
struct SettingsRowLayout: Layout {
    static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .horizontal
        return properties
    }

    private static let besideSpacing: CGFloat = 16
    private static let underSpacing: CGFloat = 8
    private static let underGap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 3 else { return .zero }
        if fitsBeside(proposal, subviews) {
            return StackRow.size(Self.beside(subviews), spacers: [1], spacing: Self.besideSpacing, proposal: proposal).size
        }
        let parts = underSizes(proposal, subviews)
        return CGSize(
            width: max(parts.text.width, parts.controls.size.width),
            height: parts.text.height + Self.underGap + parts.controls.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 3 else { return }
        if fitsBeside(proposal, subviews) {
            let row = Self.beside(subviews)
            let sizes = StackRow.size(row, spacers: [1], spacing: Self.besideSpacing, proposal: proposal)
            StackRow.place(row, sizes, spacing: Self.besideSpacing, in: bounds)
            subviews[subviews.count - 1].place(at: bounds.origin, proposal: .zero)
            return
        }
        let parts = underSizes(proposal, subviews)
        subviews[1].place(at: bounds.origin, proposal: .zero)
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: parts.text.width, height: parts.text.height))
        let frame = CGRect(
            x: bounds.minX, y: bounds.minY + parts.text.height + Self.underGap,
            width: parts.controls.size.width, height: parts.controls.size.height)
        StackRow.place(Self.under(subviews), parts.controls, spacing: Self.underSpacing, in: frame)
    }

    /// The text, the first spacer and the control's views.
    private static func beside(_ subviews: Subviews) -> [LayoutSubview] { Array(subviews.dropLast()) }

    /// The control's views and the last spacer.
    private static func under(_ subviews: Subviews) -> [LayoutSubview] { Array(subviews.dropFirst(2)) }

    /// The `ViewThatFits` test: the row's ideal width, at the height offered, fits the width offered.
    private func fitsBeside(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Bool {
        guard let width = proposal.width else { return true }
        let ideal = StackRow.size(
            Self.beside(subviews), spacers: [1], spacing: Self.besideSpacing,
            proposal: ProposedViewSize(width: nil, height: proposal.height))
        return ideal.size.width <= width
    }

    /// The text, and the row of the control, one above the other, as the vertical stack offers them the width.
    private func underSizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (text: CGSize, controls: StackRow.Sizes)
    {
        let offer = ProposedViewSize(width: proposal.width, height: nil)
        let controls = Self.under(subviews)
        let sizes = StackRow.size(controls, spacers: [controls.count - 1], spacing: Self.underSpacing, proposal: offer)
        return (subviews[0].sizeThatFits(offer), sizes)
    }
}

/// A horizontal stack's layout of a few subviews, the way `HStack` shares its width: the spacing and the spacers'
/// least lengths come off first; each other child, the least flexible first, is offered an equal share of what is left
/// and takes what it needs; the spacers share what remains. `spacers` are the indices of the `Spacer`s.
enum StackRow {
    struct Sizes {
        var sizes: [CGSize]
        var size: CGSize
    }

    static func size(
        _ subviews: [LayoutSubview], spacers: Set<Int>, spacing: CGFloat, proposal: ProposedViewSize
    ) -> Sizes {
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        var sizes = Array(repeating: CGSize.zero, count: subviews.count)
        if let width = proposal.width {
            let least = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width }
            let flexibility = subviews.indices.map { index -> CGFloat in
                subviews[index].sizeThatFits(ProposedViewSize(width: .infinity, height: proposal.height)).width
                    - least[index]
            }
            var remaining = max(0, width - gaps - spacers.reduce(0) { $0 + least[$1] })
            let views = subviews.indices.filter { !spacers.contains($0) }
            var left = views.count
            for index in views.sorted(by: { flexibility[$0] < flexibility[$1] }) {
                let offer = remaining / CGFloat(left)
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: offer, height: proposal.height))
                sizes[index] = size
                remaining = max(0, remaining - size.width)
                left -= 1
            }
            for index in spacers {
                let share = least[index] + remaining / CGFloat(spacers.count)
                sizes[index] = subviews[index].sizeThatFits(ProposedViewSize(width: share, height: proposal.height))
            }
        } else {
            sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)) }
        }
        let width = sizes.reduce(0) { $0 + $1.width } + gaps
        let height = sizes.map(\.height).max() ?? 0
        return Sizes(sizes: sizes, size: CGSize(width: width, height: height))
    }

    /// Places the views side by side from the left, each centred on the row's middle (the stacks' `.center`).
    static func place(_ subviews: [LayoutSubview], _ row: Sizes, spacing: CGFloat, in bounds: CGRect) {
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size = row.sizes[index]
            let y = bounds.midY - size.height / 2
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

/// The symbol and fill of a row's icon plate.
struct SettingsIcon {
    let symbol: String
    let tint: Color
}
