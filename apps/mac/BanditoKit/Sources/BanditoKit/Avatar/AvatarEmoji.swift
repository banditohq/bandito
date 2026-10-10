import Foundation

/// The emoji an avatar can show in place of its face.
public enum AvatarEmoji {
    /// Forty-eight popular emoji, one character each, for the emoji grid.
    public static let popular: [String] = [
        "🦝", "🦊", "🐱", "🐶", "🦁", "🐼", "🐸", "🐵", "🦉", "🐧", "🦄", "🐙", "🐢", "🦋", "🐝", "🦈",
        "🌟", "🔥", "💡", "⚡", "🎯", "🚀", "🛠️", "🔧", "📦", "📝", "📚", "🧠", "💻", "🔍", "🧪", "🎨",
        "🎵", "🌈", "☕", "🍕", "🎲", "🏆", "💎", "🌍", "🛰️", "✨", "🧩", "🪄", "🌙", "🍀", "🎁", "❤️",
    ]

    /// Whether `character` is an emoji: an emoji-presentation character (🦝, ☕, 🚀), a ZWJ sequence or flag built from
    /// them, or a character that asks for emoji presentation with VS16 (❤️, 🛠️). Plain letters, digits and the
    /// symbols that are text by default (#, ©) are not.
    public static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        // A text-default symbol is an emoji only with VS16; a digit with it is a keycap, which is not offered here.
        let hasVS16 = scalars.contains { $0.value == 0xFE0F }
        return hasVS16 && first.properties.isEmoji && !first.properties.isASCIIHexDigit
    }

    /// The newest emoji in `text`: the last character that is an emoji. Nil when there is none. Used when the owner
    /// types or inserts an emoji; a letter or a digit typed after it does not replace it.
    public static func last(of text: String) -> String? {
        text.last(where: isEmoji).map(String.init)
    }

    /// The Unicode names of the characters in `emoji`, lowercased and joined by spaces (🦝 is "raccoon", ❤️ is
    /// "heavy black heart"). The variation selector and the joiner carry no name. English only.
    public static func searchName(of emoji: String) -> String {
        emoji.unicodeScalars
            .filter { $0.value != 0xFE0F && $0.value != 0x200D }
            .compactMap { $0.properties.name?.lowercased() }
            .joined(separator: " ")
    }

    /// The emoji of `items` whose Unicode name contains every word of `query` (case does not matter). A blank query
    /// keeps them all, in order.
    public static func search(_ query: String, in items: [String]) -> [String] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let name = searchName(of: item)
            return words.allSatisfy { name.contains($0) }
        }
    }
}
