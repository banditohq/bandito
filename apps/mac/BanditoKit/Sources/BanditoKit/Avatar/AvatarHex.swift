import Foundation

/// The custom tile color of an avatar. On the wire it is `#RRGGBB` in upper case; the palette colors are names.
public enum AvatarHex {
    /// `#RRGGBB` in upper case, from `#rrggbb` or `rrggbb`. Nil for anything else.
    public static func normalized(_ text: String) -> String? {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    /// The 0xRRGGBB value of a color the wire carries (`#RRGGBB`). Nil for a palette name or anything malformed.
    public static func value(_ wire: String) -> UInt32? {
        guard let normalized = normalized(wire) else { return nil }
        return UInt32(normalized.dropFirst(), radix: 16)
    }

    /// `#RRGGBB` from sRGB components in 0...1 (clamped), as a colour picker reports them.
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ component: Double) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
