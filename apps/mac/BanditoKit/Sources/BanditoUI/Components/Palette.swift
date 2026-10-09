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

/// Colors used by components that have no exact entry in `Color.Bandito`
/// (see `brand/tokens/tokens.json`). Values that match a token reuse it.
enum BanditoPalette {
    /// Peach avatar tile (#FFB067). Same value as the dark `signal-glow` token.
    static let peach = Color.Bandito.signalGlow
    /// Lilac avatar tile (#C8B6E8). No token exists for it.
    static let lilac = Color(hex: 0xC8B6E8)
    /// Idle status dot (#6E655A), darker than `text3`. Used for dots only.
    static let idle = Color(hex: 0x6E655A)
}
