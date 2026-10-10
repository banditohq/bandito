import BanditoDesign
import SwiftUI

/// Card surface: a solid surface1 fill, a hairline border that fades from top to bottom, and a light line along
/// the top inside edge. Selected cards add a signal tint and a cream border. Apply with `.banditoCard(selected:hoverLift:)`.
public struct BanditoCardModifier: ViewModifier {
    /// Whether the card is in the selected state (signal tint and cream border).
    public var selected: Bool
    /// Whether the card lifts on hover. Use it for cards the user clicks.
    public var hoverLift: Bool

    /// Mockup radius is 14–16; 14 is used for option cards and list groups.
    static let cornerRadius: CGFloat = 14

    @State private var hovered = false

    public init(selected: Bool = false, hoverLift: Bool = false) {
        self.selected = selected
        self.hoverLift = hoverLift
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let lifted = hoverLift && hovered
        let border: AnyShapeStyle = selected
            ? AnyShapeStyle(Color.Bandito.text.opacity(0.45))
            : AnyShapeStyle(
                LinearGradient(
                    colors: [Color.Bandito.text.opacity(0.09), Color.Bandito.text.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom))
        content
            .background {
                ZStack {
                    shape.fill(Color.Bandito.surface1)
                    if selected {
                        shape.fill(Color.Bandito.signal.opacity(0.08))
                    }
                }
                // The shadow is drawn only while a clickable card is hovered.
                .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 14, y: 8)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            // Inner highlight: a 1 pt line just inside the top edge, clipped to the rounded corners.
            .overlay {
                Rectangle()
                    .fill(Color.Bandito.text.opacity(0.06))
                    .frame(height: 1)
                    .padding(.top, 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
            .offset(y: lifted ? -1.5 : 0)
            .onHover { hovered = $0 }
            .banditoAnimation(.spring(response: 0.25, dampingFraction: 0.85), value: lifted)
    }
}

public extension View {
    /// Wraps the view in the Bandito card surface.
    /// - Parameters:
    ///   - selected: Signal tint and cream border.
    ///   - hoverLift: Lifts 1.5 pt with a shadow on hover. Pass `true` for cards the user clicks.
    func banditoCard(selected: Bool = false, hoverLift: Bool = false) -> some View {
        modifier(BanditoCardModifier(selected: selected, hoverLift: hoverLift))
    }
}
