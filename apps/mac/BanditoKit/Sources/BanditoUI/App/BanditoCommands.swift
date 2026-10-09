import BanditoKit
import BanditoL10n
import SwiftUI

/// The menu bar commands. Every item takes its shortcut from `Keymap`, so a rebinding applies at once.
///
/// View holds the modes, the sidebar and the usage popover. Go holds history and agent switching.
/// Agent holds what the selected agent does. Settings is ⌘, by default.
@MainActor
public struct BanditoCommands: Commands {
    private let keymap: Keymap
    private let router: Router
    private let app: AppModel

    public init(keymap: Keymap, router: Router, app: AppModel) {
        self.keymap = keymap
        self.router = router
        self.app = app
    }

    public var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            item("global.settings") { WindowActions.showSettings() }
        }
        // ⌘W is the terminal close in the Terminals mode, so the window closes with ⇧⌘W.
        CommandGroup(replacing: .saveItem) {
            Button(L10n.Keys.closeWindow) { WindowActions.closeKeyWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .sidebar) {
            item("global.mode.team") { router.select(mode: .team) }
            item("global.mode.files") { router.select(mode: .files) }
            item("global.mode.terminals") { router.select(mode: .terminals) }
            item("global.mode.browser") { router.select(mode: .browser) }
            item("global.mode.screen") { router.select(mode: .screen) }
            item("global.mode.server") { router.select(mode: .server) }
            Divider()
            item("global.toggleSidebar") { router.toggleSidebar() }
            item("global.usage") { router.usagePopoverOpen.toggle() }
        }
        CommandMenu(L10n.Menu.go) {
            item("global.back") { router.back() }
                .disabled(!router.canGoBack)
            item("global.forward") { router.forward() }
                .disabled(!router.canGoForward)
            Divider()
            item("global.quickOpen") { router.paletteOpen.toggle() }
            item("global.searchHistory") { router.paletteOpen = true }
            Divider()
            item("team.needsYou") { selectWhoNeedsYou() }
            item("team.previousAgent") { moveSelection(by: -1) }
            item("team.nextAgent") { moveSelection(by: 1) }
        }
        CommandMenu(L10n.Menu.terminals) {
            terminal("terminals.new", .new)
            terminal("terminals.splitVertical", .splitVertical)
            terminal("terminals.splitHorizontal", .splitHorizontal)
            Divider()
            terminal("terminals.collapse", .collapse)
            terminal("terminals.restoreCollapsed", .restoreLast)
            Divider()
            terminal("terminals.paneLeft", .move(.left))
            terminal("terminals.paneRight", .move(.right))
            terminal("terminals.paneUp", .move(.up))
            terminal("terminals.paneDown", .move(.down))
            Divider()
            terminal("terminals.close", .close)
            terminal("terminals.clear", .clear)
            Divider()
            terminal("terminals.fontBigger", .fontBigger)
            terminal("terminals.fontSmaller", .fontSmaller)
            terminal("terminals.fontReset", .fontReset)
        }
        CommandMenu(L10n.Menu.agent) {
            item("global.newAgent") { router.sheet = .newAgent }
            item("team.agentDetails") { router.inspectorOpen.toggle() }
            item("team.whatChanged") { openChanges() }
            Divider()
            item("team.approve") { resolveFirstApproval(.allow) }
                .disabled(!hasPendingApproval)
            item("team.deny") { resolveFirstApproval(.deny) }
                .disabled(!hasPendingApproval)
            Divider()
            item("team.stop") { interruptSelected() }
                .disabled(selectedAgentID == nil)
            // Pausing every agent needs a daemon method that does not exist yet.
            item("team.pauseAll") {}
                .disabled(true)
        }
    }

    /// A menu item for `commandID`, titled and shortcut from the registry.
    private func item(_ commandID: String, action: @escaping () -> Void) -> some View {
        Button(Command.find(commandID)?.title ?? commandID, action: action)
            .banditoShortcut(keymap.binding(for: commandID))
    }

    /// A terminal command: it is handed to the Terminals mode, so it only works while that mode is shown.
    private func terminal(_ commandID: String, _ action: TerminalRequest.Action) -> some View {
        item(commandID) { router.terminalRequest = TerminalRequest(action) }
            .disabled(router.mode != .terminals)
    }

    // MARK: actions

    private var selectedAgentID: String? {
        guard let id = router.selectedAgentID, app.currentServer?.agents.contains(where: { $0.id == id }) == true
        else { return nil }
        return id
    }

    private var hasPendingApproval: Bool {
        guard let server = app.currentServer, let id = selectedAgentID else { return false }
        return !server.thread(for: id).pendingApprovals.isEmpty
    }

    private func selectWhoNeedsYou() {
        guard let server = app.currentServer else { return }
        guard let agent = server.sortedAgents.first(where: { server.thread(for: $0.id).status == .needsYou }) else {
            return
        }
        router.selectedAgentID = agent.id
        router.select(mode: .team)
    }

    /// Steps through the agents in sidebar order. With nothing selected, the first one is picked.
    private func moveSelection(by step: Int) {
        guard let server = app.currentServer, !server.sortedAgents.isEmpty else { return }
        let agents = server.sortedAgents
        let index = agents.firstIndex { $0.id == router.selectedAgentID } ?? (step > 0 ? -1 : agents.count)
        let next = (index + step + agents.count) % agents.count
        router.selectedAgentID = agents[next].id
        router.select(mode: .team)
    }

    private func openChanges() {
        guard let id = selectedAgentID else { return }
        router.sheet = .changes(agentID: id)
    }

    private func resolveFirstApproval(_ decision: Decision) {
        guard let server = app.currentServer, let id = selectedAgentID,
            let approval = server.thread(for: id).pendingApprovals.first
        else { return }
        Task { try? await server.resolve(approval.approvalId, decision) }
    }

    private func interruptSelected() {
        guard let server = app.currentServer, let id = selectedAgentID else { return }
        Task { try? await server.interrupt(id) }
    }
}

extension View {
    /// Applies a shortcut when there is one; a command rebound to nothing has no shortcut.
    @ViewBuilder
    func banditoShortcut(_ binding: KeyBinding?) -> some View {
        if let shortcut = binding?.keyboardShortcut {
            self.keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
