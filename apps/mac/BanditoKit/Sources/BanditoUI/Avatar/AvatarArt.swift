import BanditoDesign
import BanditoKit
import CoreGraphics
import SwiftUI

/// An avatar drawn from its parts: the picture when there is one, else the emoji on the tile color, else the raccoon
/// face. Pure drawing; loading the picture is the caller's job (see `AgentAvatarView`).
struct AvatarArtView: View {
    let name: String
    let look: AvatarLook
    let picture: CGImage?
    var size: CGFloat = 40
    var mood: AvatarMood = .idle

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(tileShape)
            } else if case let .emoji(emoji) = AvatarPresentation.choose(hasPicture: false, emoji: look.emoji) {
                emojiTile(emoji)
            } else {
                RaccoonAvatar(
                    name: name, color: look.palette, face: look.face, size: size, mood: mood,
                    customHex: look.customHex)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 17 / 52, style: .continuous)
    }

    /// The emoji on the tile the raccoon would have: the custom color, else the palette color.
    private func emojiTile(_ emoji: String) -> some View {
        let tint = look.customHex.flatMap(AvatarHex.value).map { Color(hex: $0) } ?? look.palette.color
        return tileShape
            .fill(tint)
            .overlay {
                Text(emoji)
                    .font(BanditoFont.text(size: size * 0.52, weight: 400))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
    }
}
