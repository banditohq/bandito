import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The background color row of the avatar editor: the six palette colors and a seventh, the owner's own. All 24 pt
/// circles; the chosen one has a ring. No captions: every circle names itself in its tooltip.
struct AvatarColorRow: View {
    @Binding var look: AvatarLook

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AvatarColor.allCases, id: \.self) { candidate in
                paletteSwatch(candidate)
            }
            customSwatch
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Avatar.color)
    }

    private func ring(_ selected: Bool) -> some View {
        Circle()
            .stroke(selected ? Color.Bandito.text : Color.clear, lineWidth: 2)
            .frame(width: 32, height: 32)
    }

    private func paletteSwatch(_ candidate: AvatarColor) -> some View {
        let selected = look.customHex == nil && look.palette == candidate
        return Button {
            look.palette = candidate
            look.customHex = nil
        } label: {
            Circle()
                .fill(candidate.color)
                .frame(width: 24, height: 24)
                .overlay(ring(selected))
                .frame(width: 32, height: 32)
        }
        .banditoButton(.row(cornerRadius: 16, hoverOpacity: 0.08))
        .help(colorName(candidate))
        .accessibilityLabel(colorName(candidate))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The seventh circle: a rainbow until the owner picks a color, then that color with a pipette. The system color
    /// picker sits invisibly on top, so a click anywhere on the circle opens it. The choice is stored as `#RRGGBB`.
    private var customSwatch: some View {
        let hex = look.customHex.flatMap(AvatarHex.value)
        let selected = look.customHex != nil
        return ZStack {
            Circle().fill(
                AngularGradient(
                    colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
            if let hex {
                Circle().fill(Color(hex: hex))
                Image(systemName: "eyedropper")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1.5)
            }
            ColorPicker(L10n.Avatar.customColor, selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 24, height: 24)
                .scaleEffect(2)
                .opacity(0.02)
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay(ring(selected))
        .frame(width: 32, height: 32)
        .help(L10n.Avatar.customColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Avatar.customColor)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                if let hex = look.customHex.flatMap(AvatarHex.value) { return Color(hex: hex) }
                return look.palette.color
            },
            set: { value in
                let components = NSColor(value).usingColorSpace(.sRGB) ?? NSColor.gray
                look.customHex = AvatarHex.hex(
                    red: components.redComponent, green: components.greenComponent, blue: components.blueComponent)
            })
    }

    private func colorName(_ color: AvatarColor) -> String {
        switch color {
        case .peach: L10n.AgentSheet.colorPeach
        case .sky: L10n.AgentSheet.colorSky
        case .sage: L10n.AgentSheet.colorSage
        case .rose: L10n.AgentSheet.colorRose
        case .lilac: L10n.AgentSheet.colorLilac
        case .cream: L10n.AgentSheet.colorCream
        }
    }
}
