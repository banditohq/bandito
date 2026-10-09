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
