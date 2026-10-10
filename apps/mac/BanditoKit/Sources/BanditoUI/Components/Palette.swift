import BanditoDesign
import SwiftUI

extension Color {
    /// sRGB color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// Colors that have no exact entry in `Color.Bandito` (see `brand/tokens/tokens.json`).
enum BanditoPalette {
    /// Warm highlight for "context almost full" (the dark `signal-glow` token, #FFB067).
    static let peach = Color.Bandito.signalGlow
    /// Idle status dot (#6E655A), darker than `text3`. Used for dots only.
    static let idle = Color(hex: 0x6E655A)

    // MARK: Settings sidebar badges

    // One fill per Settings section, as System Settings colors its icons. These are separate from the brand tokens on
    // purpose. In the dark theme `ok`, `info` and `danger` are pastel (about #A9C7A2, #A3BDEB, #F2A093): a white glyph
    // on them is unreadable, so the badges use darker fills of the same hues. Purple, teal, indigo and the grays have
    // no brand token at all. Orange is `signal`, the brand's "needs you" color, so Approvals uses it.
    static let badgeGray = Color(hex: 0x7D786F)
    static let badgeDarkGray = Color(hex: 0x4A463F)
    static let badgeBlue = Color(hex: 0x3B6FC4)
    static let badgeLightBlue = Color(hex: 0x2E8BC0)
    static let badgeGreen = Color(hex: 0x4C8A4A)
    static let badgeOrange = Color.Bandito.signal
    static let badgePurple = Color(hex: 0x7E57C2)
    static let badgeTeal = Color(hex: 0x2A9D8F)
    static let badgeRed = Color(hex: 0xC9453A)
    static let badgeIndigo = Color(hex: 0x5B5BD6)
    static let badgePink = Color(hex: 0xC2457A)
    static let badgeBrown = Color(hex: 0x8D6E4C)
    static let badgeSlate = Color(hex: 0x4F6D7A)

    // MARK: Avatars

    // Fixed brand avatar colors, same in light and dark. They do not follow theme tokens.
    static let avatarPeach = Color(hex: 0xFFB067)
    static let avatarSky = Color(hex: 0xA3BDEB)
    static let avatarSage = Color(hex: 0xA9C7A2)
    static let avatarRose = Color(hex: 0xF2A093)
    static let avatarLilac = Color(hex: 0xC8B6E8)
    static let avatarCream = Color(hex: 0xF3EBDD)
    /// Raccoon mask on every avatar: fixed #12100E, same in light and dark.
    static let avatarMask = Color(hex: 0x12100E)
}
