import Foundation

/// Fuzzy matching for the quick-open palette. Case and diacritics do not count.
///
/// Ranking, best first: the query starts the text, the query starts a word, the query appears
/// inside a word, the query's letters appear in order with gaps.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Character ranges to highlight in the text. Empty for an empty query.
        public let ranges: [Range<Int>]
    }

    public struct Ranked<Item> {
        public let item: Item
        public let match: Match
    }

    static let prefixScore = 300
    static let wordScore = 200
    static let substringScore = 100
    static let subsequenceBase = 50
    static let wordSeparators: Set<String> = [" ", "-", "_", ".", "/", ":", "·", "@"]

    public static func match(_ query: String, in text: String) -> Match? {
        let needle = query.trimmingCharacters(in: .whitespaces).map(fold)
        if needle.isEmpty { return Match(score: 0, ranges: []) }
        let hay = text.map(fold)
        guard needle.count <= hay.count else { return nil }

        // A contiguous occurrence: the first one decides the rank.
        for start in 0...(hay.count - needle.count) where Array(hay[start..<start + needle.count]) == needle {
            let score: Int
            if start == 0 {
                score = prefixScore
            } else if wordSeparators.contains(hay[start - 1]) {
                score = wordScore
            } else {
                score = substringScore
            }
            return Match(score: score, ranges: [start..<start + needle.count])
        }

        // Letters in order with gaps. Fewer skipped characters rank higher.
        var positions: [Int] = []
        var next = 0
        for (index, character) in hay.enumerated() where next < needle.count && character == needle[next] {
            positions.append(index)
            next += 1
        }
        guard next == needle.count, let first = positions.first, let last = positions.last else { return nil }
        let gaps = (last - first + 1) - needle.count
        return Match(score: max(1, subsequenceBase - gaps), ranges: runs(of: positions))
    }

    /// Items that match `query`, best match first. Equal scores keep their input order.
    public static func rank<Item>(_ query: String, _ items: [Item], text: (Item) -> String) -> [Ranked<Item>] {
        items.enumerated()
            .compactMap { index, item -> (Int, Ranked<Item>)? in
                guard let found = match(query, in: text(item)) else { return nil }
                return (index, Ranked(item: item, match: found))
            }
            .sorted { lhs, rhs in
                lhs.1.match.score != rhs.1.match.score
                    ? lhs.1.match.score > rhs.1.match.score
                    : lhs.0 < rhs.0
            }
            .map(\.1)
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Joins neighbouring positions into ranges: [0, 1, 3] becomes [0..<2, 3..<4].
    private static func runs(of positions: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for position in positions {
            if let last = result.last, last.upperBound == position {
                result[result.count - 1] = last.lowerBound..<(position + 1)
            } else {
                result.append(position..<(position + 1))
            }
        }
        return result
    }
}
