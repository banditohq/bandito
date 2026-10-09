import BanditoDesign
import SwiftUI

/// Hover and press for a clickable element. Every Bandito button style wraps its label in this.
/// `hovered` is false while the control is disabled. The focus ring is not here: it is on the button itself
/// (`brandFocusRing(shape:)`), because a `ButtonStyle` cannot read the button's focus reliably on macOS.
struct InteractiveBody<Content: View>: View {
    let isPressed: Bool
    let content: (_ hovered: Bool) -> Content

    @State private var pointerOver = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content(pointerOver && isEnabled)
            // A disabled control looks disabled: faded, with no hover and no press.
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { pointerOver = $0 }
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: pointerOver && isEnabled)
            .scaleEffect(isPressed ? 0.97 : 1)
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: isPressed)
    }
}

/// Keyboard focus ring for a button: a 2 pt signal stroke with a soft glow, drawn along `shape`.
/// It shows only while the button has keyboard focus and the last input was from the keyboard (`FocusModeTracker`).
/// The system's blue ring is switched off on the same view.
struct BrandFocusRingModifier<S: Shape>: ViewModifier {
    let shape: S

    @FocusState private var focused: Bool
    @Environment(\.focusMode) private var focusMode

    func body(content: Content) -> some View {
        let visible = focused && focusMode.mode == .keyboard
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                shape
                    .stroke(Color.Bandito.signal, lineWidth: 2)
                    .shadow(color: Color.Bandito.signalGlow.opacity(0.7), radius: 4)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: visible)
    }
}

public extension View {
    /// Draws the Bandito focus ring along `shape` on this button. Use `banditoButton(_:)` for the Bandito styles,
    /// which already call this with the right shape.
    func brandFocusRing<S: Shape>(shape: S) -> some View {
        modifier(BrandFocusRingModifier(shape: shape))
    }

    /// Hover fill for a row that is clickable by gesture (`onTapGesture`) and so cannot take a `ButtonStyle`.
    /// Buttons should use `RowButtonStyle` instead, which also gives press and focus.
    func rowHighlight(cornerRadius: CGFloat = 8) -> some View {
        modifier(RowHighlight(cornerRadius: cornerRadius))
    }

    /// Shows the pointing-hand cursor while the pointer is over the view. Only for text links (see `LinkButtonStyle`).
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}

private struct RowHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var pointerOver = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.Bandito.text.opacity(pointerOver ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { pointerOver = $0 }
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: pointerOver)
    }
}

private struct PointingHandCursor: ViewModifier {
    @State private var pointerOver = false

    func body(content: Content) -> some View {
        content
            .onHover { over in
                guard over != pointerOver else { return }
                pointerOver = over
                if over {
                    PointerCursor.pushPointingHand()
                } else {
                    PointerCursor.pop()
                }
            }
            .onDisappear {
                // A view that leaves the screen under the pointer must give the cursor back.
                if pointerOver {
                    pointerOver = false
                    PointerCursor.pop()
                }
            }
    }
}

/// Plain clickable content with a faint rounded fill on hover: list rows (agents, files, servers, palette commands,
/// menu-like lists) and icon or text buttons that had `.plain` before. Pass `hoverOpacity: 0.08` for icons.
public struct RowButtonStyle: ButtonStyle {
    /// Corner radius of the hover fill.
    public var cornerRadius: CGFloat
    /// Opacity of the `text` color used as the hover fill.
    public var hoverOpacity: Double

    public init(cornerRadius: CGFloat = 8, hoverOpacity: Double = 0.05) {
        self.cornerRadius = cornerRadius
        self.hoverOpacity = hoverOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .background(Color.Bandito.text.opacity(hovered ? hoverOpacity : 0), in: shape)
        }
    }
}

/// Text link that acts as a button: underlines on hover and shows the pointing hand.
public struct LinkButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .underline(hovered)
                .pointingHandCursor()
        }
    }
}
