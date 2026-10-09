import BanditoDesign
import SwiftUI

/// Quota bar: how much of a window is left, from 0 to 1.
/// Without `tint` the color follows the remainder: cream above 25%, orange below 25%, rose at 0.
public struct UsageBar: View {
    /// Share of the window left, 0 to 1.
    public var fraction: Double
    /// Fill color; `nil` picks it from the remainder (see the type comment).
    public var tint: Color?
    /// Height of the bar in points.
    public var height: CGFloat

    public init(fraction: Double, tint: Color? = nil, height: CGFloat = 6) {
        self.fraction = fraction
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.Bandito.text.opacity(0.08))
                Capsule()
                    .fill(resolvedTint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quota left")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }

    private var clamped: Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    private var resolvedTint: Color {
        if let tint {
            return tint
        }
        if clamped <= 0 {
            return Color.Bandito.danger
        }
        if clamped < 0.25 {
            return Color.Bandito.signal
        }
        return Color.Bandito.text
    }
}
