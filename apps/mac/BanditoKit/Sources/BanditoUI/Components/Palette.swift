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

/// Mockup colors that have no entry in `Color.Bandito` (see `brand/tokens/tokens.json`).
enum BanditoPalette {
    /// Peach (#FFB067): the "context almost full" color, brighter than the signal orange.
    static let peach = Color(hex: 0xFFB067)
    /// Idle status dot (#6E655A): darker than `text3`, used only for dots.
    static let idle = Color(hex: 0x6E655A)
}
