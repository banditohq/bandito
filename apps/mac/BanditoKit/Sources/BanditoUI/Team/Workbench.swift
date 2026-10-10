import BanditoKit
import Foundation

/// A tab of the workbench: the panel beside the chat in Team mode. The chat, a terminal, the browser, a file and
/// the agent's changes can sit on one screen.
enum WorkbenchTab: Hashable, Sendable {
    /// The agent's details (the inspector: details, memory, where it runs).
    case details
    /// A terminal session of the server. The same session as in Terminals mode.
    case terminal(sessionID: String)
    /// The browser of the server. The same model as in Browser mode.
    case browser
    /// A file on the server, shown in a viewer of its own.
    case file(path: String)
    /// Files the agent changed since the last checkpoint.
    case changes

    /// SF Symbol of the tab. The details tab shows the agent's name, a file its name; the title comes from the view.
    var systemImage: String {
        switch self {
        case .details: "info.circle"
        case .terminal: "terminal"
        case .browser: "globe"
        case .file: "doc.text"
        case .changes: "plusminus"
        }
    }

    /// The file name of a file tab, for its title. `nil` for the other tabs.
    var fileName: String? {
        guard case .file(let path) = self else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// One of the (at most two) panes of the workbench: its tabs in order, and the one on show.
struct WorkbenchPane: Equatable, Sendable {
    var tabs: [WorkbenchTab] = []
    var selected: WorkbenchTab?
}

/// The workbench of one agent: whether the panel is open, its panes (one, or two stacked), and the focused pane.
/// A tab is in at most one pane. A new tab goes to the focused pane.
struct WorkbenchState: Equatable, Sendable {
    var isOpen = false
    var panes: [WorkbenchPane] = [WorkbenchPane()]
    var focusedPane = 0

    var isSplit: Bool { panes.count > 1 }

    var allTabs: [WorkbenchTab] { panes.flatMap(\.tabs) }

    /// The pane that holds `tab`, if any.
    func paneIndex(of tab: WorkbenchTab) -> Int? {
        panes.firstIndex { $0.tabs.contains(tab) }
    }
}

/// Rules of the workbench. Pure functions: each takes a state and returns the next one. Tested alone.
enum WorkbenchRules {
    static let maxPanes = 2

    /// Shows `tab`. If it is open in any pane, that pane selects it; otherwise it is added to the focused pane and
    /// selected. The panel opens.
    static func open(_ tab: WorkbenchTab, in state: WorkbenchState) -> WorkbenchState {
        var next = normalized(state)
        next.isOpen = true
        if let index = next.paneIndex(of: tab) {
            next.panes[index].selected = tab
            next.focusedPane = index
        } else {
            let index = next.focusedPane
            next.panes[index].tabs.append(tab)
            next.panes[index].selected = tab
        }
        return next
    }

    /// Selects a tab that is already open, and focuses its pane. Does nothing for a tab that is not open.
    static func select(_ tab: WorkbenchTab, in state: WorkbenchState) -> WorkbenchState {
        guard let index = state.paneIndex(of: tab) else { return state }
        var next = state
        next.panes[index].selected = tab
        next.focusedPane = index
        return next
    }

    /// Closes a tab. The tab next to it is selected: the one that moved into its place, else the one before.
    /// A pane left empty goes away when there are two panes; with one pane, the panel closes.
    static func close(_ tab: WorkbenchTab, in state: WorkbenchState) -> WorkbenchState {
        guard let index = state.paneIndex(of: tab) else { return state }
        var next = normalized(state)
        removeTab(tab, fromPane: index, in: &next)
        if next.panes[index].tabs.isEmpty {
            if next.panes.count > 1 {
                next.panes.remove(at: index)
            } else {
                next.isOpen = false
            }
        }
        return normalized(next)
    }

    /// Adds a second pane below the first. It shows the details tab when that tab is not open yet; otherwise it is
    /// empty, and the view offers the tabs to open there. The new pane is focused. Does nothing when already split.
    static func split(_ state: WorkbenchState) -> WorkbenchState {
        guard state.panes.count < maxPanes else { return state }
        var next = normalized(state)
        var pane = WorkbenchPane()
        if next.paneIndex(of: .details) == nil {
            pane.tabs = [.details]
            pane.selected = .details
        }
        next.panes.append(pane)
        next.focusedPane = next.panes.count - 1
        next.isOpen = true
        return next
    }

    /// Joins the panes back into one: the tabs of the second pane go to the end of the first. Does nothing when
    /// there is one pane.
    static func unsplit(_ state: WorkbenchState) -> WorkbenchState {
        guard state.panes.count > 1 else { return state }
        var next = normalized(state)
        let second = next.panes.removeLast()
        next.panes[0].tabs += second.tabs
        if next.panes[0].selected == nil {
            next.panes[0].selected = second.selected
        }
        next.focusedPane = 0
        return next
    }

    /// Moves a tab into another pane and selects it there. A pane left empty by the move goes away.
    /// Does nothing when the tab is not open, the target does not exist, or the tab is already there.
    static func move(_ tab: WorkbenchTab, toPane target: Int, in state: WorkbenchState) -> WorkbenchState {
        guard let source = state.paneIndex(of: tab),
              source != target,
              state.panes.indices.contains(target)
        else { return state }
        var next = normalized(state)
        removeTab(tab, fromPane: source, in: &next)
        next.panes[target].tabs.append(tab)
        next.panes[target].selected = tab
        var focus = target
        if next.panes[source].tabs.isEmpty {
            next.panes.remove(at: source)
            if target > source { focus = target - 1 }
        }
        next.focusedPane = focus
        return normalized(next)
    }

    /// How long a tool call without a result still counts as running. An older one is a lost result, not a live call.
    static let runningToolWindowMs: Int64 = 10 * 60 * 1000

    /// A browser tool of an agent, by its name: `browser_*`, or the Bandito server's `mcp__bandito__browser_*`.
    static func isBrowserTool(_ tool: String) -> Bool {
        let name = tool.lowercased()
        return name.hasPrefix("browser_") || name.hasPrefix("mcp__bandito__browser_")
    }

    /// The names of the tools running now: calls without a result that started within `runningToolWindowMs`
    /// (a call whose start time is unknown counts as running).
    static func runningToolNames(_ rows: [ToolRow], now: Int64) -> [String] {
        rows.compactMap { row in
            guard row.ok == nil else { return nil }
            if let started = row.startedAt, now - started > runningToolWindowMs { return nil }
            return row.tool
        }
    }

    /// The chip "The agent is using the browser · Show" in the chat header. It shows while a browser tool of the
    /// agent runs, unless the browser is already the tab on show in an open panel. It only offers the tab; it never
    /// opens it.
    static func showsBrowserChip(state: WorkbenchState, runningTools: [String]) -> Bool {
        let browserOnShow = state.isOpen && state.panes.contains { $0.selected == .browser }
        return !browserOnShow && runningTools.contains { isBrowserTool($0) }
    }

    /// The pane the state focuses, if its index is in range.
    static func focusedPane(of state: WorkbenchState) -> WorkbenchPane? {
        state.panes.indices.contains(state.focusedPane) ? state.panes[state.focusedPane] : nil
    }

    /// The pane at `index`, or an empty pane when there is none: the view keeps a second pane in its tree while the
    /// panel is not split.
    static func pane(_ index: Int, of state: WorkbenchState) -> WorkbenchPane {
        state.panes.indices.contains(index) ? state.panes[index] : WorkbenchPane()
    }

    /// The ⌘J rule: an open panel closes; a closed one opens on its selected tab, or on the details when it has none.
    static func toggle(_ state: WorkbenchState) -> WorkbenchState {
        if state.isOpen {
            var next = state
            next.isOpen = false
            return next
        }
        if state.allTabs.isEmpty {
            return open(.details, in: state)
        }
        var next = state
        next.isOpen = true
        return next
    }

    /// The agent details are on show: the panel is open and a pane has the details tab selected.
    static func showsDetails(_ state: WorkbenchState) -> Bool {
        state.isOpen && state.panes.contains { $0.selected == .details }
    }

    // MARK: helpers

    /// Removes `tab` from pane `index` and selects its neighbour when it was the selected one.
    private static func removeTab(_ tab: WorkbenchTab, fromPane index: Int, in state: inout WorkbenchState) {
        guard let position = state.panes[index].tabs.firstIndex(of: tab) else { return }
        state.panes[index].tabs.remove(at: position)
        guard state.panes[index].selected == tab else { return }
        let tabs = state.panes[index].tabs
        state.panes[index].selected = tabs.isEmpty ? nil : tabs[min(position, tabs.count - 1)]
    }

    /// The focus index kept inside the panes (the panes never go empty of focus).
    private static func normalized(_ state: WorkbenchState) -> WorkbenchState {
        var next = state
        if next.panes.isEmpty { next.panes = [WorkbenchPane()] }
        next.focusedPane = min(max(next.focusedPane, 0), next.panes.count - 1)
        return next
    }
}

/// Size of the workbench: the width is one for the whole app; the split is the share of the top pane.
enum WorkbenchLayout {
    static let defaultWidth: Double = 460
    static let minWidth: Double = 320
    /// The panel never takes more than this share of the window.
    static let maxWidthShare: Double = 0.7
    static let defaultSplit: Double = 0.5
    static let splitRange: ClosedRange<Double> = 0.2...0.8

    static let widthKey = "bandito.workbench.width"
    static let splitKey = "bandito.workbench.split"

    /// The panel width kept inside the bounds for a window of `windowWidth`. The minimum wins on a tiny window.
    static func clampWidth(_ width: Double, windowWidth: Double) -> Double {
        let upper = max(minWidth, windowWidth * maxWidthShare)
        return min(max(width, minWidth), upper)
    }

    /// The share of the top pane, kept within 20…80 %.
    static func clampSplit(_ share: Double) -> Double {
        min(max(share, splitRange.lowerBound), splitRange.upperBound)
    }
}
