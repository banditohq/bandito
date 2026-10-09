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
    case settings(SettingsSection)

    public var id: String {
        switch self {
        case .newAgent: "newAgent"
        case .changes(let agentID): "changes-\(agentID)"
        case .addServer: "addServer"
        case .account: "account"
        case .settings(let section): "settings-\(section.rawValue)"
        }
    }
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
    /// Browser: the open tab.
    public var browserTabID: String?
    /// Server screen: the screen being shown.
    public var screenID: String?
    /// Server: the section in view.
    public var serverSection: ServerSection = .overview
    /// Browser: a port to open a preview of (Server → Open). Taken once by the browser.
    public var pendingPreviewPort: Int?
    /// Terminals: a command to type into a new terminal (Server → Install, Update). Taken once by the terminals.
    public var pendingTerminalCommand: String?

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

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Switches to `next`. Selecting the current mode does nothing. A new switch clears forward history.
    public func select(mode next: AppMode) {
        guard next != mode else { return }
        backStack.append(mode)
        forwardStack.removeAll()
        mode = next
    }

    /// Returns to the previous mode (⌘[ or a swipe to the right).
    public func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(mode)
        mode = previous
    }

    /// Goes forward again after `back()` (⌘] or a swipe to the left).
    public func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(mode)
        mode = next
    }

    public func toggleSidebar() {
        sidebarVisible.toggle()
    }
}
