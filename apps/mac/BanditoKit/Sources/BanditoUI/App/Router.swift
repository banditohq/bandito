import BanditoL10n
import Observation

/// The six sections of the main window. The mode bar and ⌘1…⌘6 switch between them.
public enum AppMode: String, CaseIterable, Identifiable, Sendable {
    case team, files, terminals, browser, screen, server

    public var id: String { rawValue }

    /// Name shown in the mode bar tooltip and the section header.
    public var title: String {
        switch self {
        case .team: L10n.Mode.team
        case .files: L10n.Mode.files
        case .terminals: L10n.Mode.terminals
        case .browser: L10n.Mode.browser
        case .screen: L10n.Mode.screen
        case .server: L10n.Mode.server
        }
    }

    /// SF Symbol shown in the mode bar.
    public var systemImage: String {
        switch self {
        case .team: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .terminals: "terminal"
        case .browser: "globe"
        case .screen: "display"
        case .server: "waveform.path.ecg"
        }
    }
}

/// A modal sheet over the main window.
public enum Sheet: Identifiable, Hashable, Sendable {
    case newAgent
    case changes(agentID: String)
    case addServer
    /// Sign in or create an account (Onboarding's account step, reused from Settings).
    case account

    public var id: String {
        switch self {
        case .newAgent: "newAgent"
        case .changes(let agentID): "changes-\(agentID)"
        case .addServer: "addServer"
        case .account: "account"
        }
    }
}

/// The tabs of the agent details panel (⌘I, and `/memory` opens the memory one).
enum InspectorTab: String, CaseIterable, Hashable, Sendable {
    case details, memory, whereRuns
}

/// Navigation state of one main window: the current mode, what is selected in each mode,
/// open sheets and panels, and back/forward history between modes.
///
/// Selections are kept when the mode changes, so coming back to a mode lands on the same item.
@MainActor
@Observable
public final class Router {
    public private(set) var mode: AppMode

    /// Team: the agent whose chat is open.
    public var selectedAgentID: String?
    /// Files: the folder being browsed, absolute on the server. `nil` means the agent's home.
    public var filesPath: String?
    /// Files: a file to open in the viewer once its folder (`filesPath`) is listed. Taken once.
    public private(set) var pendingFilePath: String?
    /// Files: the open files and their editors. Kept here so they survive switching modes.
    let files = FileWorkspace()
    /// Terminals: the terminal pane in focus.
    public var terminalID: String?
    /// Terminals: the folder a new terminal should start in ("Terminal here"). Taken once by the terminals.
    public var pendingTerminalCwd: String?
    /// New agent sheet: the folder the agent should work in ("Create agent in this folder"). Taken once by the sheet.
    public var pendingAgentCwd: String?
    /// Team: text for the composer of the selected agent ("Ask about this place"). Taken once by the thread.
    public var pendingComposerText: String?
    /// Team: the composer of this agent should take keyboard focus (⌘↵ in the palette, after opening the agent).
    /// Taken once, by the composer of that agent only.
    public private(set) var composerFocusAgentID: String?
    /// Terminals: a command from the menu bar, waiting for the Terminals mode to perform it.
    public var terminalRequest: TerminalRequest?
    /// Browser: the open tab.
    public var browserTabID: String?
    /// Browser: a port an agent opened ("Open" in the sidebar, or the Agents section). Taken once by the browser mode.
    public var pendingPreviewPort: Int?
    /// Server screen: the screen being shown.
    public var screenID: String?
    /// Server: the section in view.
    public var serverSection: ServerSection = .overview
    /// Terminals: a command to type into a new terminal (Server → Install, Update). Taken once by the terminals.
    public var pendingTerminalCommand: String?

    /// The tab of the agent details panel. Kept here so `/memory` can open it on the memory tab.
    var inspectorTab: InspectorTab = .details

    public var sheet: Sheet?
    /// The quick-open palette (⌘K).
    public var paletteOpen = false
    /// The subscription limits popover, opened from the sidebar footer (⌥⌘U).
    public var usagePopoverOpen = false
    /// The agent details inspector (⌘I).
    public var inspectorOpen = false
    /// The sidebar column (⌃⌘S).
    public var sidebarVisible = true

    private var backStack: [AppMode] = []
    private var forwardStack: [AppMode] = []

    public init(mode: AppMode = .team) {
        self.mode = mode
    }

    /// In Files, back and forward walk the folders visited on the server (`FolderHistory`), not the modes.
    public var canGoBack: Bool {
        mode == .files ? files.canStepBack || files.showsViewer : !backStack.isEmpty
    }

    public var canGoForward: Bool {
        mode == .files ? files.canStepForward : !forwardStack.isEmpty
    }

    /// Switches to `next`. Selecting the current mode does nothing. A new switch clears forward history.
    public func select(mode next: AppMode) {
        guard next != mode else { return }
        backStack.append(mode)
        forwardStack.removeAll()
        mode = next
    }

    /// Returns to the previous mode (⌘[ or a swipe to the right). In Files it goes back one folder instead; with
    /// no folder left to go back to, an open file viewer closes and the folder shows.
    public func back() {
        if mode == .files {
            if let path = files.stepBack() {
                showFolder(path)
            } else if files.showsViewer {
                files.showsViewer = false
            }
            return
        }
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(mode)
        mode = previous
    }

    /// Goes forward again after `back()` (⌘] or a swipe to the left). In Files it goes forward one folder.
    public func forward() {
        if mode == .files {
            if let path = files.stepForward() { showFolder(path) }
            return
        }
        guard let next = forwardStack.popLast() else { return }
        backStack.append(mode)
        mode = next
    }

    /// A folder chosen with the history steps: the browser shows it, even when a file was open in the viewer.
    private func showFolder(_ path: String) {
        filesPath = path
        files.showsViewer = false
    }

    public func toggleSidebar() {
        sidebarVisible.toggle()
    }

    // MARK: handing actions to a mode
    //
    // Each `pending…` field is taken by exactly one view. The take clears the field, so a second
    // view (or a re-appearing one) does not repeat the action.

    public func takeTerminalCommand() -> String? {
        defer { pendingTerminalCommand = nil }
        return pendingTerminalCommand
    }

    public func takeTerminalCwd() -> String? {
        defer { pendingTerminalCwd = nil }
        return pendingTerminalCwd
    }

    public func takeAgentCwd() -> String? {
        defer { pendingAgentCwd = nil }
        return pendingAgentCwd
    }

    public func takeComposerText() -> String? {
        defer { pendingComposerText = nil }
        return pendingComposerText
    }

    public func takePreviewPort() -> Int? {
        defer { pendingPreviewPort = nil }
        return pendingPreviewPort
    }

    /// Shows a folder or a file in Files: a folder becomes `filesPath`; a file opens in the viewer, in its folder.
    public func openInFiles(_ path: String, isFile: Bool) {
        if isFile {
            filesPath = FilePath.parent(of: path) ?? filesPath
            pendingFilePath = path
        } else {
            filesPath = path
        }
        select(mode: .files)
    }

    public func takePendingFilePath() -> String? {
        defer { pendingFilePath = nil }
        return pendingFilePath
    }

    /// Asks the composer of `agentID` to take focus. The request is taken by `takeComposerFocus(agentID:)`.
    public func requestComposerFocus(agentID: String) {
        composerFocusAgentID = agentID
    }

    /// True once per request, and only for the agent the request names: the first matching call returns true
    /// and clears the request. Other composers leave it alone.
    public func takeComposerFocus(agentID: String) -> Bool {
        guard composerFocusAgentID == agentID else { return false }
        composerFocusAgentID = nil
        return true
    }

    /// "Open terminal here": the Terminals mode opens a new terminal in `folder` once the server's terminals
    /// are listed (the folder waits in `pendingTerminalCwd` until then).
    public func openTerminalHere(_ folder: String) {
        pendingTerminalCwd = folder
        select(mode: .terminals)
    }

    /// A terminal command for the Terminals mode, and the mode switch in the same step, so the command runs
    /// now and is never left waiting for the mode to open later.
    public func requestTerminalCommand(_ command: String) {
        pendingTerminalCommand = command
        select(mode: .terminals)
    }

    /// Drops the actions aimed at the server that was in front: a folder, a command, a port, a text or a file
    /// of another server would be wrong here. Called when the server in front changes.
    public func dropPendingServerActions() {
        pendingTerminalCommand = nil
        pendingTerminalCwd = nil
        pendingAgentCwd = nil
        pendingComposerText = nil
        pendingPreviewPort = nil
        pendingFilePath = nil
        composerFocusAgentID = nil
    }

    /// Opens the agent details panel on `tab`.
    func openInspector(_ tab: InspectorTab) {
        inspectorTab = tab
        inspectorOpen = true
    }
}
