/// The open files of the viewer, in tab order, with the one in front. Paths are absolute on the server.
struct ViewerTabs: Equatable, Sendable {
    private(set) var paths: [String] = []
    private(set) var selected: String?

    /// Opens `path` in a new tab at the end, or just shows it if it is open already.
    mutating func open(_ path: String) {
        if !paths.contains(path) { paths.append(path) }
        selected = path
    }

    /// Closes `path`. If it was in front, the tab that took its place comes to the front.
    mutating func close(_ path: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        paths.remove(at: index)
        guard selected == path else { return }
        selected = paths.isEmpty ? nil : paths[min(index, paths.count - 1)]
    }

    /// Ctrl-Tab: the next tab, wrapping around.
    mutating func selectNext() {
        guard !paths.isEmpty else { return }
        let index = paths.firstIndex(of: selected ?? "") ?? -1
        selected = paths[(index + 1) % paths.count]
    }

    /// Ctrl-Shift-Tab: the previous tab, wrapping around.
    mutating func selectPrevious() {
        guard !paths.isEmpty else { return }
        let index = paths.firstIndex(of: selected ?? "") ?? 0
        selected = paths[(index - 1 + paths.count) % paths.count]
    }
}
