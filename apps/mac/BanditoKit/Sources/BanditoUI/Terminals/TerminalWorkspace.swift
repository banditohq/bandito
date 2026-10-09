import Foundation
import Observation

/// Which terminals are on screen, in which layout, and which ones are collapsed into the dock.
///
/// Pure state: it knows terminal ids, not their output. `TerminalController` drives it from user actions
/// and from the server's list, and saves it per server in UserDefaults (`terminals.workspace.<server id>`).
/// At most `TerminalLayout.grid.capacity` panes are on screen. A pane beyond that waits in the dock.
@MainActor
@Observable
public final class TerminalWorkspace {
    /// A pane in the dock. `lines` is the output line count when it was collapsed, so the dock can show
    /// "+N lines"; it is `nil` for panes restored from disk, whose count starts with the next run.
    public struct Collapsed: Sendable, Equatable {
        public var id: String
        public var collapsedAt: Date
        public var lines: Int?
    }

    public private(set) var layout: TerminalLayout = .one
    /// Panes on screen, in layout order: `onScreen[i]` is in cell `i`.
    public private(set) var onScreen: [String] = []
    /// Collapsed panes, oldest first. The last one is what ⌘⇧T brings back.
    public private(set) var collapsed: [Collapsed] = []
    public private(set) var focusedID: String?
    /// The pane shown full size, if any. Its siblings stay alive but are hidden.
    public private(set) var fullscreenID: String?
    /// When on, typing in the focused pane is sent to every pane on screen too.
    public var inputToAll = false {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    public init(serverID: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storageKey = "terminals.workspace.\(serverID.uuidString)"
        load()
    }

    /// Every terminal the workspace knows, on screen or collapsed.
    public var knownIDs: Set<String> {
        Set(onScreen).union(collapsed.map(\.id))
    }

    // MARK: adding and placing

    public enum Placement: Sendable, Equatable {
        case screen, dock
    }

    /// Puts a new terminal on screen, growing the layout if it fits a bigger one, and focuses it.
    /// When the grid is full it goes to the dock instead.
    @discardableResult
    public func add(_ id: String, afterFocused: Bool = false, at time: Date) -> Placement {
        guard !knownIDs.contains(id) else {
            focus(id)
            return onScreen.contains(id) ? .screen : .dock
        }
        if place(id, afterFocused: afterFocused) {
            save()
            return .screen
        }
        collapsed.append(Collapsed(id: id, collapsedAt: time, lines: nil))
        save()
        return .dock
    }

    /// Moves a collapsed pane back to the screen and focuses it. Fails when the grid is full.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        guard let index = collapsed.firstIndex(where: { $0.id == id }) else { return false }
        let entry = collapsed.remove(at: index)
        guard place(id, afterFocused: false) else {
            collapsed.insert(entry, at: index)
            return false
        }
        save()
        return true
    }

    /// Brings back the most recently collapsed pane. Returns its id, or `nil` if there is none (or no room).
    @discardableResult
    public func restoreLast() -> String? {
        guard let last = collapsed.last?.id, restore(last) else { return nil }
        return last
    }

    // MARK: moving out and closing

    /// Moves a pane from the screen to the dock. It keeps running; the caller records its line count.
    public func collapse(_ id: String, at time: Date, lines: Int) {
        guard let index = onScreen.firstIndex(of: id) else { return }
        onScreen.remove(at: index)
        collapsed.append(Collapsed(id: id, collapsedAt: time, lines: lines))
        if fullscreenID == id { fullscreenID = nil }
        repairFocus(preferring: index)
        save()
    }

    /// Forgets a terminal that was closed, wherever it is.
    public func close(_ id: String) {
        let index = onScreen.firstIndex(of: id)
        onScreen.removeAll { $0 == id }
        collapsed.removeAll { $0.id == id }
        if fullscreenID == id { fullscreenID = nil }
        repairFocus(preferring: index ?? 0)
        save()
    }

    /// Swaps one terminal id for another in the same place (used when a terminal is restarted).
    public func replace(_ old: String, with new: String) {
        if let index = onScreen.firstIndex(of: old) {
            onScreen[index] = new
            if focusedID == old { focusedID = new }
            if fullscreenID == old { fullscreenID = new }
        } else if let index = collapsed.firstIndex(where: { $0.id == old }) {
            collapsed[index].id = new
        }
        save()
    }

    // MARK: layout, focus, fullscreen

    /// Switches the arrangement. Panes beyond the new capacity move to the dock, last ones first to go.
    public func setLayout(_ next: TerminalLayout, at time: Date) {
        layout = next
        if onScreen.count > next.capacity {
            let overflow = onScreen[next.capacity...]
            onScreen.removeSubrange(next.capacity...)
            collapsed += overflow.map { Collapsed(id: $0, collapsedAt: time, lines: nil) }
            if let fullscreenID, overflow.contains(fullscreenID) { self.fullscreenID = nil }
        }
        repairFocus(preferring: 0)
        save()
    }

    public func focus(_ id: String) {
        guard onScreen.contains(id) else { return }
        focusedID = id
        save()
    }

    /// Moves the focus to the neighbor of the focused pane in `direction`, if there is one.
    public func move(_ direction: TerminalDirection) {
        guard let focusedID, let index = onScreen.firstIndex(of: focusedID),
            let target = layout.neighbor(of: index, direction), target < onScreen.count
        else { return }
        focus(onScreen[target])
    }

    public func toggleFullscreen(_ id: String) {
        guard onScreen.contains(id) else { return }
        if fullscreenID == id {
            fullscreenID = nil
        } else {
            fullscreenID = id
            focusedID = id
        }
        save()
    }

    public func exitFullscreen() {
        guard fullscreenID != nil else { return }
        fullscreenID = nil
        save()
    }

    // MARK: sync with the server

    /// Matches the workspace with the server's terminals. Ids the server no longer has are dropped. Terminals
    /// the app has never seen (started elsewhere, or before the app restarted) go to the dock, oldest first.
    public func reconcile(serverTerminals: [(id: String, createdAt: Int64)]) {
        let serverIDs = Set(serverTerminals.map(\.id))
        let before = knownIDs
        onScreen.removeAll { !serverIDs.contains($0) }
        collapsed.removeAll { !serverIDs.contains($0.id) }
        if let fullscreenID, !onScreen.contains(fullscreenID) { self.fullscreenID = nil }

        let unknown = serverTerminals
            .filter { !before.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        for terminal in unknown {
            collapsed.append(
                Collapsed(
                    id: terminal.id,
                    collapsedAt: Date(timeIntervalSince1970: TimeInterval(terminal.createdAt) / 1000),
                    lines: nil))
        }
        repairFocus(preferring: 0)
        save()
    }

    // MARK: internals

    /// Puts `id` in the next free cell, growing the layout when needed. Returns false when the grid is full.
    private func place(_ id: String, afterFocused: Bool) -> Bool {
        if onScreen.count >= layout.capacity {
            guard let next = TerminalLayout.next(fitting: onScreen.count + 1) else { return false }
            layout = next
        }
        var index = onScreen.count
        if afterFocused, let focusedID, let focused = onScreen.firstIndex(of: focusedID) {
            index = focused + 1
        }
        onScreen.insert(id, at: index)
        focusedID = id
        return true
    }

    /// Keeps the focus on a pane that is on screen: the one that now sits where the old one was, else the first.
    private func repairFocus(preferring index: Int) {
        if let focusedID, onScreen.contains(focusedID) { return }
        guard !onScreen.isEmpty else {
            focusedID = nil
            return
        }
        focusedID = onScreen[min(max(index, 0), onScreen.count - 1)]
    }

    private struct Snapshot: Codable {
        struct Entry: Codable {
            var id: String
            var collapsedAt: Double
        }

        var layout: TerminalLayout
        var onScreen: [String]
        var collapsed: [Entry]
        var focusedID: String?
        var inputToAll: Bool
    }

    private func save() {
        let snapshot = Snapshot(
            layout: layout,
            onScreen: onScreen,
            collapsed: collapsed.map { Snapshot.Entry(id: $0.id, collapsedAt: $0.collapsedAt.timeIntervalSince1970) },
            focusedID: focusedID,
            inputToAll: inputToAll)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        layout = snapshot.layout
        onScreen = Array(snapshot.onScreen.prefix(layout.capacity))
        collapsed = snapshot.collapsed.map {
            Collapsed(id: $0.id, collapsedAt: Date(timeIntervalSince1970: $0.collapsedAt), lines: nil)
        }
        focusedID = snapshot.focusedID
        repairFocus(preferring: 0)
        inputToAll = snapshot.inputToAll
    }
}
