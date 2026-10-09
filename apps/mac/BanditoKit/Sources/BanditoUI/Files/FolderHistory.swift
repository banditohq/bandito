/// The folders visited in one server's Files, for `<` and `>` (⌘[ and ⌘]), as in Finder.
///
/// A visit that changes the folder adds it after the current one and drops whatever was ahead of it. A step
/// back or forward only moves along the list. Visiting the folder that is already current adds nothing.
struct FolderHistory: Equatable, Sendable {
    /// The most folders kept. The oldest go first.
    static let limit = 100

    private(set) var paths: [String] = []
    /// Position of the current folder in `paths`; `nil` before the first visit.
    private var index: Int?

    var current: String? {
        index.map { paths[$0] }
    }

    var canGoBack: Bool {
        (index ?? 0) > 0
    }

    var canGoForward: Bool {
        guard let index else { return false }
        return index < paths.count - 1
    }

    /// The folder on screen is `path`. Records it unless it is the current folder already.
    mutating func visit(_ path: String) {
        guard current != path else { return }
        if let index {
            paths.removeLast(paths.count - index - 1)
        }
        paths.append(path)
        if paths.count > Self.limit {
            paths.removeFirst(paths.count - Self.limit)
        }
        index = paths.count - 1
    }

    /// Moves to the folder before the current one. Returns it, or `nil` if there is none.
    mutating func back() -> String? {
        guard canGoBack, let index else { return nil }
        self.index = index - 1
        return current
    }

    /// Moves to the folder after the current one. Returns it, or `nil` if there is none.
    mutating func forward() -> String? {
        guard canGoForward, let index else { return nil }
        self.index = index + 1
        return current
    }
}
