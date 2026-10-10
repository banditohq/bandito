import BanditoDesign
import SwiftUI

/// The one look of every text input in the app: a `surface2` fill, 10 pt continuous corners and a 1 pt hairline.
/// On focus the border turns cream (text 30%) and a soft signal glow sits outside the fill. The system's blue focus
/// ring is switched off. An error draws the border in `danger` at 60%.
/// Use `.banditoField(error:)` for `TextField` and `SecureField`, and `.banditoEditor(error:)` for `TextEditor`.
public enum BanditoFieldLook {
    /// Corner radius of the input.
    public static let cornerRadius: CGFloat = 10
    /// Height of a single-line input.
    public static let minHeight: CGFloat = 36

    /// Border opacity of the text color: 8% at rest, 30% with focus.
    public static func borderOpacity(focused: Bool) -> Double { focused ? 0.30 : 0.08 }

    /// Opacity of the signal glow: 8% with focus, none otherwise. An error shows no glow.
    public static func glowOpacity(focused: Bool, error: Bool) -> Double { focused && !error ? 0.08 : 0 }
}

/// `TextFieldStyle` behind `.banditoField(error:)`. The focus state comes from the modifier, because a style cannot
/// read the focus of its field on macOS reliably.
public struct BanditoFieldStyle: TextFieldStyle {
    public var focused: Bool
    public var error: Bool

    public init(focused: Bool = false, error: Bool = false) {
        self.focused = focused
        self.error = error
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .modifier(BanditoFieldChrome(focused: focused, error: error, verticalPadding: 9))
    }
}

/// Fill, border, glow, text and padding shared by fields and editors.
private struct BanditoFieldChrome: ViewModifier {
    let focused: Bool
    let error: Bool
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: BanditoFieldLook.cornerRadius, style: .continuous)
        let border = error
            ? Color.Bandito.danger.opacity(0.6)
            : Color.Bandito.text.opacity(BanditoFieldLook.borderOpacity(focused: focused))
        content
            .font(BanditoFont.text(size: 13.5, weight: 400))
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: BanditoFieldLook.minHeight, alignment: .leading)
            .background {
                shape.fill(Color.Bandito.surface2)
                    .shadow(color: Color.Bandito.signal.opacity(BanditoFieldLook.glowOpacity(focused: focused, error: error)),
                            radius: 8)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: focused)
    }
}

/// Owns the focus of one input and applies the look to it.
private struct BanditoFieldModifier: ViewModifier {
    let error: Bool

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        // A plain field with the chrome drawn around it: a custom TextFieldStyle on macOS still keeps the system bezel
        // inside, which showed as a grey field within the warm one.
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .modifier(BanditoFieldChrome(focused: focused, error: error, verticalPadding: 9))
    }
}

/// Owns the focus of one editor and applies the same look to it.
private struct BanditoEditorModifier: ViewModifier {
    let error: Bool

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .scrollContentBackground(.hidden)
            .modifier(BanditoFieldChrome(focused: focused, error: error, verticalPadding: 9))
    }
}

public extension View {
    /// The Bandito input look for a `TextField` or `SecureField`. Replaces `.textFieldStyle(.plain)` and `.roundedBorder`.
    /// - Parameter error: Draws the border in `danger`, for an invalid value.
    func banditoField(error: Bool = false) -> some View {
        modifier(BanditoFieldModifier(error: error))
    }

    /// The Bandito input look for a `TextEditor`. Same fill, border and focus glow as `banditoField(error:)`.
    /// - Parameter error: Draws the border in `danger`, for an invalid value.
    func banditoEditor(error: Bool = false) -> some View {
        modifier(BanditoEditorModifier(error: error))
    }
}
