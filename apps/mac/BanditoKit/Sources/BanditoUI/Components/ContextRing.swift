import BanditoDesign
import SwiftUI

/// Ring showing how full the context window is. Sage while there is room, peach above 80%.
public struct ContextRing: View {
    public var fraction: Double
    public var size: CGFloat

    public init(fraction: Double, size: CGFloat = 16) {
        self.fraction = fraction
        self.size = size
    }

    public var body: some View {
        let value = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let lineWidth = max(1.5, size * 0.11)
        ZStack {
            Circle()
                .stroke(Color.Bandito.text.opacity(0.12), lineWidth: lineWidth)
            if value > 0 {
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(
                        value > 0.8 ? BanditoPalette.peach : Color.Bandito.ok,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        // Inset by half the stroke so the ring stays inside the frame.
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}
