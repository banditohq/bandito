import BanditoDesign
import SwiftUI

/// Card surface: faint fill and hairline border. Selected cards take a signal tint.
/// Apply with `.banditoCard(selected:)`.
public struct BanditoCardModifier: ViewModifier {
    /// Whether the card is in the selected state (signal tint and border).
    public var selected: Bool

    /// Mockup radius is 14–16; 14 is used for option cards and list groups.
    static let cornerRadius: CGFloat = 14

    public init(selected: Bool = false) {
        self.selected = selected
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content
            .background(shape.fill(selected ? Color.Bandito.signal.opacity(0.08) : Color.Bandito.text.opacity(0.025)))
            .overlay(
                shape.stroke(
                    selected ? Color.Bandito.signal.opacity(0.45) : Color.Bandito.text.opacity(0.08),
                    lineWidth: 1)
            )
    }
}

public extension View {
    /// Wraps the view in the Bandito card surface.
    func banditoCard(selected: Bool = false) -> some View {
        modifier(BanditoCardModifier(selected: selected))
    }
}
