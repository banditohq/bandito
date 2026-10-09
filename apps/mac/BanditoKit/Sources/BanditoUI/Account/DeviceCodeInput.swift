import Foundation

/// The 16-character code that names a device (`XXXX-XXXX-XXXX-XXXX`), typed or pasted. Input is cleaned as it
/// arrives: upper case, only the characters the code can contain (RFC 4648 base32), at most 16, grouped by four.
struct DeviceCodeInput: Equatable, Sendable {
    static let length = 16
    static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// The formatted text, possibly partial.
    private(set) var value = ""

    /// The 16 characters without the dashes.
    var raw: String {
        value.filter { $0 != "-" }
    }

    var isComplete: Bool {
        raw.count == Self.length
    }

    /// Replaces the text with the cleaned `text` (a typed character or a whole paste).
    mutating func enter(_ text: String) {
        let symbols = text.uppercased().filter { Self.alphabet.contains($0) }.prefix(Self.length)
        value = Self.grouped(String(symbols))
    }

    /// Groups `raw` by four with dashes: "K7QF2MXA" -> "K7QF-2MXA".
    static func grouped(_ raw: String) -> String {
        let symbols = Array(raw)
        return stride(from: 0, to: symbols.count, by: 4)
            .map { String(symbols[$0..<min($0 + 4, symbols.count)]) }
            .joined(separator: "-")
    }
}
