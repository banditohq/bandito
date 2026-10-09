import Foundation

/// Rules for secret names and values. The same checks as the daemon makes (docs/ARCHITECTURE.md#secrets),
/// so the app can refuse a bad name before it is sent.
public enum SecretRules {
    /// Largest value in bytes.
    public static let maxValueBytes = 65_536

    static let reservedNames: Set<String> = ["PATH", "HOME", "USER", "SHELL", "LD_PRELOAD", "LD_LIBRARY_PATH"]
    static let reservedPrefixes = ["DYLD_", "BANDITO_"]

    /// `^[A-Z_][A-Z0-9_]{0,63}$`, and not a reserved name or prefix.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, isUpperOrUnderscore(first) else {
            return false
        }
        guard bytes.dropFirst().allSatisfy({ isUpperOrUnderscore($0) || (48...57).contains($0) }) else {
            return false
        }
        if reservedNames.contains(name) { return false }
        return !reservedPrefixes.contains { name.hasPrefix($0) }
    }

    /// 1 to 65 536 bytes, and no NUL byte.
    public static func isValidValue(_ value: String) -> Bool {
        let count = value.utf8.count
        return (1...maxValueBytes).contains(count) && !value.contains("\0")
    }

    private static func isUpperOrUnderscore(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || byte == 95
    }
}
