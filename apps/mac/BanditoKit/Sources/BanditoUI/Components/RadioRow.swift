import BanditoDesign
import SwiftUI

/// Selectable option card: radio marker, title, optional description and badge.
/// The selected marker is a white center inside a 5 pt signal ring.
public struct RadioRow: View {
    public let title: String
    public let description: String?
    public let badge: String?
    public let isSelected: Bool
    public let action: () -> Void

    /// - Parameters:
    ///   - title: Option name.
    ///   - description: One line of detail under the title.
    ///   - badge: Short hint next to the title, e.g. "рекомендуем" (shown as an ok chip).
    ///   - isSelected: Whether this option is the current choice.
    ///   - action: Called when the row is tapped.
    public init(
        title: String,
        description: String? = nil,
        badge: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.badge = badge
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                RadioMark(isSelected: isSelected)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(BanditoFont.text(size: 13.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        if let badge {
                            Chip(text: badge, tone: .ok)
                        }
                    }
                    if let description {
                        Text(description)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .banditoCard(selected: isSelected)
        }
        .banditoButton(.row(cornerRadius: 14))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Radio circle: unselected is a hairline ring, selected is a white center in a 5 pt signal ring.
private struct RadioMark: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(isSelected ? Color.Bandito.onSignal : Color.clear)
            .overlay(
                Circle().strokeBorder(
                    isSelected ? Color.Bandito.signalFill : Color.Bandito.text.opacity(0.25),
                    lineWidth: isSelected ? 5 : 1.5)
            )
            .frame(width: 16, height: 16)
    }
}
