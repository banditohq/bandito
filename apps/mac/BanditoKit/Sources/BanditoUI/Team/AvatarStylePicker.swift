import BanditoDesign
import BanditoL10n
import SwiftUI

/// The avatar's color and face, as one row: the color swatches, then the faces. Used by the new agent sheet and by the
/// avatar popover in the inspector.
struct AvatarStylePicker: View {
    @Binding var color: AvatarColor
    @Binding var face: AvatarFace

    var body: some View {
        HStack(spacing: 7) {
            ForEach(AvatarColor.allCases, id: \.self) { candidate in
                colorButton(candidate)
            }
            Rectangle().fill(Color.Bandito.text.opacity(0.1)).frame(width: 1, height: 18).padding(.horizontal, 3)
            Text(L10n.AgentSheet.faceLabel)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            ForEach(AvatarFace.faces, id: \.self) { candidate in
                faceButton(candidate)
            }
        }
    }

    private func colorButton(_ candidate: AvatarColor) -> some View {
        Button {
            color = candidate
        } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(candidate.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if color == candidate {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(candidate.color, lineWidth: 1.5)
                            .frame(width: 28, height: 28)
                    }
                }
        }
        .banditoButton(.row(cornerRadius: 9, hoverOpacity: 0.08))
        .accessibilityLabel(colorName(candidate))
        .accessibilityAddTraits(color == candidate ? .isSelected : [])
    }

    private func faceButton(_ candidate: AvatarFace) -> some View {
        let selected = face == candidate
        return Button {
            face = candidate
        } label: {
            Text(AvatarFace.glyph(candidate))
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text3)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    selected ? Color.Bandito.text.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
        .accessibilityLabel(faceName(candidate))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private func faceName(_ face: AvatarFace) -> String {
        switch face {
        case .auto, .chevronDash: L10n.AgentSheet.faceSquint
        case .dots: L10n.AgentSheet.faceDots
        case .carets: L10n.AgentSheet.faceSmile
        }
    }
}
