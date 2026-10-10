import Foundation

/// The keyboard highlight of a select panel. Works over the rows that are shown, in order (after a search), and
/// `enabled` says for each row whether it can be chosen. Pure, so the keys are tested without a view.
public enum SelectHighlight {
    /// Where the highlight starts when the panel opens: on the selected row when it is shown and enabled, otherwise on
    /// the first enabled row. Nil when no row can be chosen.
    public static func initial(enabled: [Bool], selectedIndex: Int?) -> Int? {
        if let selectedIndex, enabled.indices.contains(selectedIndex), enabled[selectedIndex] {
            return selectedIndex
        }
        return enabled.firstIndex(of: true)
    }

    /// The enabled row below `current`, skipping disabled rows. Stays on `current` at the last enabled row. From no
    /// highlight, it is the first enabled row.
    public static func next(from current: Int?, enabled: [Bool]) -> Int? {
        guard let current else { return enabled.firstIndex(of: true) }
        let below = enabled.indices.filter { $0 > current && enabled[$0] }
        return below.first ?? (enabled.indices.contains(current) && enabled[current] ? current : nil)
    }

    /// The enabled row above `current`, skipping disabled rows. Stays on `current` at the first enabled row. From no
    /// highlight, it is the last enabled row.
    public static func previous(from current: Int?, enabled: [Bool]) -> Int? {
        guard let current else { return enabled.lastIndex(of: true) }
        let above = enabled.indices.filter { $0 < current && enabled[$0] }
        return above.last ?? (enabled.indices.contains(current) && enabled[current] ? current : nil)
    }
}

/// One section of a panel after the search: its heading and the options it still shows.
public struct SelectGroup<Value: Hashable> {
    public let title: String?
    public let options: [SelectOption<Value>]

    public init(title: String?, options: [SelectOption<Value>]) {
        self.title = title
        self.options = options
    }
}

/// The search of a select panel and its size.
public enum SelectFilter {
    /// The search field shows only when there are more options than this.
    public static let searchThreshold = 8

    public static func showsSearch(optionCount: Int) -> Bool {
        optionCount > searchThreshold
    }

    /// Whether an option is shown for `query`: every word of the query is found in its title or its subtitle, ignoring
    /// case and accents. An empty query shows everything.
    public static func matches(query: String, title: String, subtitle: String?) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, subtitle ?? ""]
        return words.allSatisfy { word in
            haystack.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The sections of the panel after the query: each keeps the options the query leaves, and empty sections are
    /// dropped. The order of sections and options is kept.
    public static func groups<Value: Hashable>(
        _ sections: [SelectSection<Value>], query: String
    ) -> [SelectGroup<Value>] {
        sections.map { section in
            SelectGroup(
                title: section.title,
                options: section.options.filter {
                    matches(query: query, title: $0.title, subtitle: $0.subtitle)
                })
        }
        .filter { !$0.options.isEmpty }
    }

    /// The width of the panel: the field's width, kept between 280 and 520 points.
    public static func panelWidth(fieldWidth: CGFloat) -> CGFloat {
        min(max(fieldWidth, 280), 520)
    }
}
