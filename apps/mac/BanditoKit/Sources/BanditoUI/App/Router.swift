import BanditoKit
import BanditoL10n
import Observation

/// The seven sections of the main window. The mode bar and ⌘1…⌘7 switch between them.
public enum AppMode: String, CaseIterable, Identifiable, Sendable {
    case team, files, terminals, browser, screen, market, server

    public var id: String { rawValue }

    /// Name shown in the mode bar tooltip and the section header.
    public var title: String {
        switch self {
        case .team: L10n.Mode.team
        case .files: L10n.Mode.files
        case .terminals: L10n.Mode.terminals
        case .browser: L10n.Mode.browser
        case .screen: L10n.Mode.screen
        case .market: L10n.Mode.market
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
        case .market: "puzzlepiece.extension"
        case .server: "waveform.path.ecg"
        }
    }
}

/// The filter of the Marketplace sidebar: every service, or only the connected ones.
public enum MarketFilter: String, CaseIterable, Identifiable, Sendable {
    case all, connected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: L10n.Market.Filter.all
        case .connected: L10n.Market.Filter.connected
        }
    }
}

/// A modal sheet over the main window.
public enum Sheet: Identifiable, Hashable, Sendable {
    case newAgent
    case addServer
    /// Sign in or create an account (Onboarding's account step, reused from Settings).
    case account
    /// A new schedule of the agent (`existing` nil), or the change of an existing one. Shown on the main window,
    /// not on the inspector, which is too narrow for it.
    case schedule(agentID: String, existing: Schedule?)

    public var id: String {
        switch self {
        case .newAgent: "newAgent"
        case .addServer: "addServer"
        case .account: "account"
        case .schedule(let agentID, let existing): "schedule-\(agentID)-\(existing?.id ?? "new")"
        }
    }
}

/// What Browser mode gives the router so back and forward act on the page's history while it is on screen.
struct BrowserHistoryHandle {
    var canBack: () -> Bool
    var canForward: () -> Bool
    var back: () -> Void
    var forward: () -> Void
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

    /// Team: the agent whose chat is open. Choosing one leaves the team home.
    public var selectedAgentID: String? {
        didSet {
            if selectedAgentID != nil { showsTeamHome = false }
        }
    }
    /// Team: the home screen (greeting, templates, recent agents) is shown instead of a chat.
    public private(set) var showsTeamHome = false
    /// Team: the agent whose chat the home replaced, for "forward" (a swipe to the left) to return to.
    private(set) var agentBeforeHome: String?
    /// Browser: back and forward walk the page's history while Browser mode is on screen (⌘[ ⌘] and the menu).
    @ObservationIgnored var browserHistory: BrowserHistoryHandle?
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
    /// New agent sheet: the starting template chosen on the empty team. Taken once by the sheet.
    public var pendingTemplate: AgentTemplate?
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
    /// Marketplace: the filter the sidebar picked (all services or the connected ones).
    public var marketFilter: MarketFilter = .all
    /// Terminals: a command to type into a new terminal (Server → Install, Update). Taken once by the terminals.
    public var pendingTerminalCommand: String?

    /// The tab of the agent details panel. Kept here so `/memory` can open it on the memory tab.
    var inspectorTab: InspectorTab = .details

    /// The agent whose chat is on screen (set by Team mode). ⌘I, ⌘J and the workbench shortcuts act on it.
    var shownAgentID: String?
    /// The server in front (set by the main window). Workbench state belongs to an agent of this server.
    var frontServerID: String?

    /// The workbench panel of each agent, by `workbenchKey`: its tabs and panes (see `WorkbenchRules`).
    var workbench: [String: WorkbenchState] = [:]
    /// Failures of the workbench's actions, by `workbenchKey`. Shown in the panel until dismissed.
    private var notices: [String: UserFacingMessage] = [:]
    /// Agents whose workbench is opening a terminal now, by `workbenchKey`. A second request waits for the first.
    private var terminalsOpening: Set<String> = []

    /// The key of an agent's workbench state: the server and the agent, since agent ids repeat across servers.
    static func workbenchKey(server: String?, agentID: String) -> String {
        "\(server ?? "")|\(agentID)"
    }

    func workbenchKey(_ agentID: String) -> String {
        Self.workbenchKey(server: frontServerID, agentID: agentID)
    }

    /// The agent the shortcuts act on: the one on screen, else the selected one.
    private var actingAgentID: String? { shownAgentID ?? selectedAgentID }

    /// The workbench of an agent; a closed, empty one when the agent has none yet.
    func workbenchState(for agentID: String) -> WorkbenchState {
        workbench[workbenchKey(agentID)] ?? WorkbenchState()
    }

    /// Applies a change to the workbench of an agent and keeps the result.
    func updateWorkbench(for agentID: String, _ change: (WorkbenchState) -> WorkbenchState) {
        workbench[workbenchKey(agentID)] = change(workbenchState(for: agentID))
    }

    /// Drops everything the workbench keeps for a deleted agent.
    func forgetWorkbench(agentID: String) {
        let key = workbenchKey(agentID)
        workbench[key] = nil
        notices[key] = nil
        terminalsOpening.remove(key)
        if shownAgentID == agentID { shownAgentID = nil }
    }

    /// The failure shown in the panel of an agent, if any.
    func workbenchNotice(for agentID: String) -> UserFacingMessage? {
        notices[workbenchKey(agentID)]
    }

    func setWorkbenchNotice(_ message: UserFacingMessage?, for agentID: String) {
        notices[workbenchKey(agentID)] = message
    }

    /// Marks that a terminal for `agentID` is opening. `false` when one already is: the request is dropped.
    func beginOpeningTerminal(agentID: String) -> Bool {
        terminalsOpening.insert(workbenchKey(agentID)).inserted
    }

    func endOpeningTerminal(agentID: String) {
        terminalsOpening.remove(workbenchKey(agentID))
    }

    public var sheet: Sheet?
    /// The quick-open palette (⌘K).
    public var paletteOpen = false
    /// The subscription limits popover, opened from the sidebar footer (⌥⌘U).
    public var usagePopoverOpen = false
    /// The agent details are on show in the workbench of the selected agent (⌘I). Read-only: change it with
    /// `toggleDetails()` or `openInspector(_:)`.
    var inspectorOpen: Bool {
        actingAgentID.map { WorkbenchRules.showsDetails(workbenchState(for: $0)) } ?? false
    }

    /// The toast after a rollback from "What changed", with the undo. Shown over the window.
    var rollbackNotice: RollbackNotice?
    /// The sidebar column (⌃⌘S).
    public var sidebarVisible = true

    private var backStack: [AppMode] = []
    private var forwardStack: [AppMode] = []

    public init(mode: AppMode = .team) {
        self.mode = mode
    }

    /// In Files, back and forward walk the folders visited on the server (`FolderHistory`), not the modes.
    public var canGoBack: Bool {
        if mode == .browser, let browserHistory { return browserHistory.canBack() }
        return mode == .files ? files.canStepBack || files.showsViewer : !backStack.isEmpty
    }

    public var canGoForward: Bool {
        if mode == .browser, let browserHistory { return browserHistory.canForward() }
        return mode == .files ? files.canStepForward : !forwardStack.isEmpty
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
        if mode == .browser, let browserHistory {
            browserHistory.back()
            return
        }
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
        if mode == .browser, let browserHistory {
            browserHistory.forward()
            return
        }
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

    /// Opens the team home (the sidebar's TEAM label, ⌘0, a swipe to the right in a chat). The chat that was open is
    /// remembered for `leaveTeamHome()`.
    public func showTeamHome() {
        if !showsTeamHome { agentBeforeHome = shownAgentID ?? selectedAgentID }
        // No chat is open on the home: the commands that act on "the agent on screen" (the menu, ⌘↵, ⌘., ⇧⌘D, the
        // palette) have no agent to act on, so they stay off instead of working on a chat nobody sees.
        selectedAgentID = nil
        shownAgentID = nil
        showsTeamHome = true
        select(mode: .team)
    }

    /// Leaves the team home for the chat it replaced; with none remembered, the team's usual agent opens.
    public func leaveTeamHome() {
        guard showsTeamHome else { return }
        let agent = agentBeforeHome
        agentBeforeHome = nil
        showsTeamHome = false
        if let agent { selectedAgentID = agent }
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

    /// The person chose an agent (a click, a shortcut, a new agent). It is selected and remembered as the one to open
    /// first on its server. Selection the app makes by itself (the team's fallback, a deleted agent) does not go through here.
    public func selectAgent(_ agentID: String, on server: ServerModel?) {
        selectedAgentID = agentID
        if let server {
            LastOpenedAgent.save(agentID, serverID: server.id.uuidString)
        }
    }

    public func takePendingTemplate() -> AgentTemplate? {
        defer { pendingTemplate = nil }
        return pendingTemplate
    }

    /// The composer's text of each agent, by agent id. Kept here rather than in the thread view, so a draft stays with
    /// its agent when the view is recreated or the person goes to another agent.
    public var drafts: [String: String] = [:]
    /// Counts each ⌘R. The thread and the folder on show reload their data when it changes (see `RefreshRules`).
    var refreshRequests = 0
    /// Where each agent's thread was left (see `ThreadPlace`). Not observed: only the thread reads and writes it, and
    /// a scroll must not redraw the screens that observe the router.
    @ObservationIgnored var threadPlaces: [String: ThreadPlace] = [:]

    /// The draft of an agent, trimmed, for sending; the draft is cleared.
    public func takeDraft(for agentID: String) -> String {
        let text = (drafts[agentID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[agentID] = nil
        return text
    }

    /// Puts text that could not be sent back into the draft of its own agent, in front of anything typed since.
    public func restoreDraft(_ text: String, for agentID: String) {
        let typed = drafts[agentID] ?? ""
        let typedNothing = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        drafts[agentID] = typedNothing ? text : text + "\n" + typed
    }

    /// Adds text to the draft of an agent, after what is there (a line break in between).
    public func appendDraft(_ text: String, for agentID: String) {
        let current = drafts[agentID] ?? ""
        drafts[agentID] = current.isEmpty ? text : current + "\n" + text
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
        agentBeforeHome = nil
    }

    /// Opens the agent details on `tab` (`/memory` opens the memory tab): the details tab of the selected agent's
    /// workbench is shown, with that tab selected inside it.
    func openInspector(_ tab: InspectorTab) {
        inspectorTab = tab
        if let agentID = actingAgentID {
            showInWorkbench(.details, agentID: agentID)
        }
    }

    // MARK: workbench

    /// Shows `tab` in the workbench of `agentID` and opens the panel (buttons, menus, the memory viewer).
    func showInWorkbench(_ tab: WorkbenchTab, agentID: String) {
        let before = workbenchState(for: agentID)
        updateWorkbench(for: agentID) { WorkbenchRules.open(tab, in: $0) }
        if workbenchState(for: agentID) != before { SoundPlayer.play(.tab) }
    }

    /// Shows `tab` in pane `index` of the workbench of `agentID`: the pane the person pressed in.
    func showInWorkbench(_ tab: WorkbenchTab, agentID: String, pane index: Int) {
        let before = workbenchState(for: agentID)
        updateWorkbench(for: agentID) { WorkbenchRules.open(tab, inPane: index, in: $0) }
        if workbenchState(for: agentID) != before { SoundPlayer.play(.tab) }
    }

    /// Selects a tab that is already open in the workbench of `agentID`.
    func selectWorkbenchTab(_ tab: WorkbenchTab, agentID: String) {
        let before = workbenchState(for: agentID)
        updateWorkbench(for: agentID) { WorkbenchRules.select(tab, in: $0) }
        if workbenchState(for: agentID) != before { SoundPlayer.play(.tab) }
    }

    /// Closes a tab of the workbench of `agentID`.
    func closeWorkbenchTab(_ tab: WorkbenchTab, agentID: String) {
        updateWorkbench(for: agentID) { WorkbenchRules.close(tab, in: $0) }
    }

    /// Makes pane `index` of the workbench of `agentID` the one new tabs go to.
    func focusWorkbenchPane(_ index: Int, agentID: String) {
        updateWorkbench(for: agentID) { state in
            guard state.panes.indices.contains(index) else { return state }
            var next = state
            next.focusedPane = index
            return next
        }
    }

    /// Moves a tab of the workbench of `agentID` into pane `index`.
    func moveWorkbenchTab(_ tab: WorkbenchTab, toPane index: Int, agentID: String) {
        updateWorkbench(for: agentID) { WorkbenchRules.move(tab, toPane: index, in: $0) }
    }

    /// Splits the workbench of `agentID` into two panes, or joins them back (⌘⌥\).
    func toggleWorkbenchSplit(agentID: String) {
        updateWorkbench(for: agentID) { state in
            state.isSplit ? WorkbenchRules.unsplit(state) : WorkbenchRules.split(state)
        }
    }

    /// ⌘⌥1…9: selects the tab at `index` in the focused pane of the selected agent's workbench.
    func selectFocusedWorkbenchTab(at index: Int) {
        guard let agentID = actingAgentID, let pane = WorkbenchRules.focusedPane(of: workbenchState(for: agentID)),
            pane.tabs.indices.contains(index)
        else { return }
        selectWorkbenchTab(pane.tabs[index], agentID: agentID)
    }

    /// ⌘⌥W: closes the selected tab of the focused pane of the selected agent's workbench.
    func closeFocusedWorkbenchTab() {
        guard let agentID = actingAgentID, let tab = WorkbenchRules.focusedPane(of: workbenchState(for: agentID))?.selected
        else { return }
        closeWorkbenchTab(tab, agentID: agentID)
    }

    /// Closes the workbench panel of `agentID`; its tabs stay open for the next time.
    func closeWorkbenchPanel(agentID: String) {
        updateWorkbench(for: agentID) { state in
            var next = state
            next.isOpen = false
            return next
        }
    }

    /// ⌘J: opens or closes the workbench panel of the selected agent.
    func toggleWorkbench() {
        guard let agentID = actingAgentID else { return }
        updateWorkbench(for: agentID) { WorkbenchRules.toggle($0) }
    }

    /// ⌘I: shows the agent details in the workbench, or closes the panel when the details are on show.
    func toggleDetails() {
        guard let agentID = actingAgentID else { return }
        updateWorkbench(for: agentID) { state in
            WorkbenchRules.showsDetails(state) ? WorkbenchRules.toggle(state) : WorkbenchRules.open(.details, in: state)
        }
    }
}
