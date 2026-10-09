import BanditoDesign
import SwiftUI

/// Button size. `regular` matches the Mac mockups; `large` is for the main action of a dialog.
public enum BanditoButtonSize: Sendable {
    case regular, large
}

extension BanditoButtonSize {
    var height: CGFloat {
        switch self {
        case .regular: 38
        case .large: 46
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .regular: 13.5
        case .large: 15
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: 18
        case .large: 22
        }
    }
}

/// Shared pressed feedback: slight dim and shrink. The animation honors Reduce Motion.
private struct PressFeedback: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPressed ? 0.85 : 1)
            .scaleEffect(isPressed ? 0.98 : 1)
            .banditoAnimation(BanditoMotion.ease, value: isPressed)
    }
}

/// Primary action: signal gradient, white label, orange glow. Use one per view.
public struct SignalButtonStyle: ButtonStyle {
    /// Height and label size of the button.
    public var size: BanditoButtonSize

    public init(size: BanditoButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.font(size: size.fontSize, weight: 600))
            .foregroundStyle(Color.Bandito.onSignal)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(
                LinearGradient(
                    colors: [Color.Bandito.signalFill, Color.Bandito.signalFillEnd],
                    startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Color.Bandito.onSignal.opacity(0.18), .clear],
                        startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            )
            .shadow(color: Color.Bandito.signalFill.opacity(0.8), radius: 9, x: 0, y: 6)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// Secondary action: translucent fill with a hairline border and cream label.
public struct QuietButtonStyle: ButtonStyle {
    /// Height and label size of the button.
    public var size: BanditoButtonSize

    public init(size: BanditoButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.font(size: size.fontSize, weight: 500))
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(Color.Bandito.text.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// Light pill: cream fill with dark label, for a primary action on dark dialogs.
public struct LightPillButtonStyle: ButtonStyle {
    /// Height and label size of the button.
    public var size: BanditoButtonSize

    public init(size: BanditoButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.font(size: size.fontSize, weight: 600))
            .foregroundStyle(Color.Bandito.bg)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(Color.Bandito.text, in: Capsule())
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// Square icon button (rounded 9) with a hairline border. Pass an icon as the label.
public struct IconButtonStyle: ButtonStyle {
    /// Edge of the square button in points.
    public var size: CGFloat
    /// Accessibility name of the icon, e.g. "Search". Shown to VoiceOver only.
    public var label: String

    /// - Parameters:
    ///   - size: Edge of the square button in points.
    ///   - label: Accessibility name of the icon. Localization comes with L10n later.
    public init(size: CGFloat = 30, label: String) {
        self.size = size
        self.label = label
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.Bandito.text2)
            .frame(width: size, height: size)
            .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.Bandito.text.opacity(0.08), lineWidth: 1)
            )
            .accessibilityLabel(label)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}
