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

/// Primary action: signal gradient, white label, orange glow. Use one per view.
/// On hover the fill brightens by 7% and the glow spreads. Hover, press and focus come from `InteractiveBody`.
public struct SignalButtonStyle: ButtonStyle {
    /// Height and label size of the button.
    public var size: BanditoButtonSize

    public init(size: BanditoButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .font(BanditoFont.font(size: size.fontSize, weight: 600))
                .foregroundStyle(Color.Bandito.onSignal)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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
                .brightness(hovered ? 0.07 : 0)
                .shadow(
                    color: Color.Bandito.signalFill.opacity(hovered ? 0.95 : 0.8),
                    radius: hovered ? 14 : 9, x: 0, y: 6)
        }
    }
}

/// Secondary action: translucent fill with a hairline border and cream label.
/// On hover the fill and the border get brighter.
public struct QuietButtonStyle: ButtonStyle {
    /// Height and label size of the button.
    public var size: BanditoButtonSize

    public init(size: BanditoButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .font(BanditoFont.font(size: size.fontSize, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .background(Color.Bandito.text.opacity(hovered ? 0.10 : 0.06), in: Capsule())
                .overlay(Capsule().stroke(Color.Bandito.text.opacity(hovered ? 0.22 : 0.12), lineWidth: 1))
        }
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
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .font(BanditoFont.font(size: size.fontSize, weight: 600))
                .foregroundStyle(Color.Bandito.bg)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .background(Color.Bandito.text, in: Capsule())
                .brightness(hovered ? 0.08 : 0)
                .shadow(color: Color.Bandito.text.opacity(hovered ? 0.28 : 0), radius: hovered ? 14 : 0, x: 0, y: 4)
        }
    }
}

/// Square icon button (rounded 9) with a hairline border. Pass an icon as the label.
/// On hover it gets a rounded `text` fill at 8% and the icon turns to full cream.
public struct IconButtonStyle: ButtonStyle {
    /// Edge of the square button in points.
    public var size: CGFloat
    /// Name of the icon's action, e.g. "Search". VoiceOver reads it, and `banditoButton(.icon)` shows it as the
    /// tooltip, so it says what the button does.
    public var label: String

    /// - Parameters:
    ///   - size: Edge of the square button in points.
    ///   - label: Accessibility name of the icon. Localization comes with L10n later.
    public init(size: CGFloat = 30, label: String) {
        self.size = size
        self.label = label
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .foregroundStyle(hovered ? Color.Bandito.text : Color.Bandito.text2)
                .frame(width: size, height: size)
                .background(Color.Bandito.text.opacity(hovered ? 0.08 : 0.03), in: shape)
                .overlay(shape.stroke(Color.Bandito.text.opacity(hovered ? 0.14 : 0.08), lineWidth: 1))
                .accessibilityLabel(label)
        }
    }
}

/// Filled control whose fill is the label itself (a cream send or stop disc, a gradient pill): on hover the label
/// brightens by 7%. The focus ring follows a capsule, which is a circle for square labels.
public struct BrightenButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .brightness(hovered ? 0.07 : 0)
        }
    }
}

/// Which Bandito button style a button uses. `banditoButton(_:)` applies the style and the matching focus ring,
/// so the two never disagree about the shape.
public enum BanditoButtonKind {
    case signal(size: BanditoButtonSize = .regular)
    case quiet(size: BanditoButtonSize = .regular)
    case lightPill(size: BanditoButtonSize = .regular)
    case icon(size: CGFloat = 30, label: String)
    case row(cornerRadius: CGFloat = 8, hoverOpacity: Double = 0.05)
    case link
    case brighten
}

private struct BanditoButtonModifier: ViewModifier {
    let kind: BanditoButtonKind

    @ViewBuilder
    func body(content: Content) -> some View {
        switch kind {
        case .signal(let size):
            content.buttonStyle(SignalButtonStyle(size: size)).brandFocusRing(shape: Capsule())
        case .quiet(let size):
            content.buttonStyle(QuietButtonStyle(size: size)).brandFocusRing(shape: Capsule())
        case .lightPill(let size):
            content.buttonStyle(LightPillButtonStyle(size: size)).brandFocusRing(shape: Capsule())
        case .icon(let size, let label):
            content.buttonStyle(IconButtonStyle(size: size, label: label))
                .brandFocusRing(shape: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .help(label)
        case .row(let cornerRadius, let hoverOpacity):
            content.buttonStyle(RowButtonStyle(cornerRadius: cornerRadius, hoverOpacity: hoverOpacity))
                .brandFocusRing(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .link:
            content.buttonStyle(LinkButtonStyle())
                .brandFocusRing(shape: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .brighten:
            content.buttonStyle(BrightenButtonStyle()).brandFocusRing(shape: Capsule())
        }
    }
}

public extension View {
    /// Applies a Bandito button style with its focus ring. Use it on a `Button` or `Menu` instead of `.buttonStyle(...)`.
    func banditoButton(_ kind: BanditoButtonKind) -> some View {
        modifier(BanditoButtonModifier(kind: kind))
    }
}
