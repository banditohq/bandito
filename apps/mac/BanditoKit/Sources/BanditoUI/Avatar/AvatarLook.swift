import BanditoKit
import Foundation

/// The look an owner edits: the tile color (a palette color, or a custom `#RRGGBB` that wins over it), the face and an
/// optional emoji. The picture is not part of it; the daemon keeps that apart.
struct AvatarLook: Equatable {
    var palette: AvatarColor
    /// A custom tile color as `#RRGGBB`. Nil for a palette color.
    var customHex: String?
    var face: AvatarFace
    var emoji: String?

    init(palette: AvatarColor, customHex: String?, face: AvatarFace, emoji: String?) {
        self.palette = palette
        self.customHex = customHex
        self.face = face
        self.emoji = emoji
    }

    /// The look of an avatar as saved. Where nothing is saved, or a value is unknown, the automatic color and face of
    /// `name` apply.
    init(spec: AvatarSpec?, name: String) {
        let resolved = AvatarResolver.resolve(
            name: name,
            color: spec.flatMap { AvatarColor(rawValue: $0.color) },
            face: spec.flatMap { AvatarFace(rawValue: $0.face) } ?? .auto)
        palette = resolved.color
        face = resolved.face
        customHex = spec.flatMap { AvatarHex.normalized($0.color) }
        emoji = spec?.emoji
    }

    /// The color as the wire carries it: `#RRGGBB` when custom, else the palette name.
    var wireColor: String { customHex ?? palette.rawValue }

    /// What the daemon stores for this look (`agents.update {avatar}`, `agents.create {avatar}`). Without an emoji the
    /// field is left out, which clears a saved one.
    var spec: AvatarSpec {
        AvatarSpec(color: wireColor, face: face.rawValue, emoji: emoji)
    }
}
