import Foundation

/// The role of an agent as a person sees it. A role typed with spaces, a zero-width character or a bidi mark looks
/// empty on screen, so it is cleaned before it is shown: invisible characters are dropped, control characters become a
/// space, the ends are trimmed. A role that is empty after that is no role (no chip is drawn for it).
public enum AgentRoleText {
    /// The role to show, or nil when nothing visible is left.
    public static func visible(_ role: String) -> String? {
        var cleaned = ""
        for scalar in role.unicodeScalars {
            if isInvisible(scalar) { continue }
            if scalar.properties.generalCategory == .control {
                cleaned.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Characters that take no room on screen: format characters (zero-width joiners and spaces, the BOM, bidi marks,
    /// the soft hyphen), the filler characters that look like a space but draw nothing, and the combining grapheme joiner.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .format { return true }
        switch scalar.value {
        case 0x034F, 0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0:
            return true
        default:
            return false
        }
    }
}
