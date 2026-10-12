import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Team mode: the thread of the agent on screen, with the workbench panel beside it when the agent's panel is open
/// (terminal, browser, files, changes, details). Wide enough, the panel sits beside the chat and its left edge
/// resizes it; narrow, the panel lies over the chat's right side.
/// The agent on screen is the one chosen, else the one last chosen on this server, else the first in sidebar order
/// (see `TeamSelection`). A fallback becomes the chosen one, so it does not change under the person.
struct TeamMode: View {
    /// The server this Team mode shows (one is kept built per server, see `Router.teamServers`); nil: none.
    let serverID: String?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// The panel width the person chose; one for the whole app. Kept in range by `WorkbenchLayout.clampWidth`.
    @AppStorage(WorkbenchLayout.widthKey) private var storedWidth = WorkbenchLayout.defaultWidth
    /// The width while the edge is dragged: the panel follows the pointer at once. Written to `storedWidth` only when
    /// the drag ends, so the preference is not written on every pixel.
    @State private var liveWidth: Double?
    /// Kept built under another mode or server (`KeptMode`): it acts on nothing until it shows again.
    @Environment(\.modeHidden) private var hidden
    /// What it showed last on screen. Out of sight it shows the same and reads none of the router's choices: a home
    /// opened or an agent chosen on another server would build its views again, unseen.
    @State private var last = TeamModeShown()

    var body: some View {
        let server = serverID.flatMap { id in app.servers.first { $0.id.uuidString == id } }
        let (home, agent, open) = shown(on: server)
        ZStack {
            // The chat the home replaced stays built under it (`KeptMode`): leaving the home shows it at once (making
            // it again cost about 100 ms).
            if let server, let agent {
                let kept = hidden || home
                if kept && open {
                    // A panel runs live views (a terminal, a browser): out of sight the chat is not kept with it.
                    Color.clear
                } else {
                    chatArea(server: server, agent: agent, open: open, kept: kept)
                        .keptMode(hidden: kept)
                }
            } else if !home, let server, server.state == .connected, server.agents.isEmpty {
                TeamWelcome()
            } else if !home {
                EmptyTeam()
            }
            if home, let server {
                TeamHome(server: server)
                    .id(server.id)
                    // No chat is on screen: ⌘I, ⌘J and the workbench shortcuts have nothing to act on.
                    .onChange(of: hidden, initial: true) { _, hidden in
                        if !hidden { router.shownAgentID = nil }
                    }
            }
        }
    }

    /// The home, the agent of the chat and its panel: from the router on screen, as last shown out of sight.
    private func shown(on server: ServerModel?) -> (home: Bool, agent: Agent?, open: Bool) {
        guard let server else { return (false, nil, false) }
        if hidden {
            let agent = last.agentID.flatMap { id in server.agents.first { $0.id == id } }
            return (last.home && !server.agents.isEmpty, agent, last.open)
        }
        let home = router.showsTeamHome && !server.agents.isEmpty
        let agent = home ? agentBeforeHome(on: server) : shownAgent(on: server)
        let open = agent.map { router.workbenchState(for: $0.id).isOpen } ?? false
        // A reference: kept for when it goes out of sight, redrawing nothing.
        last.home = home
        last.agentID = agent?.id
        last.open = open
        return (home, agent, open)
    }

    /// `kept`: out of sight (under the home or another mode); the chat then changes no choice.
    private func chatArea(server: ServerModel, agent: Agent, open: Bool, kept: Bool) -> some View {
        GeometryReader { proxy in
            let modeWidth = Double(proxy.size.width)
            let width = WorkbenchLayout.fittedWidth(stored: liveWidth ?? storedWidth, modeWidth: modeWidth)
            let covers = WorkbenchLayout.coversChat(modeWidth: modeWidth, panelWidth: width)
            // One tree: the chat is always the first child. The panel is placed beside it or over it.
            ZStack(alignment: .trailing) {
                // The chat changes its width once, at the first frame of the move, never frame by frame: every
                // bubble re-wraps its text when the width changes, so an animated width re-laid out the whole
                // thread at 60 fps. The transaction below cuts the animation of the inset only; the panel slides.
                chat(server: server, agent: agent)
                    .padding(.trailing, WorkbenchLayout.chatInset(open: open, covers: covers, panelWidth: width))
                    .transaction { $0.animation = nil }
                if open && covers {
                    // Over the chat the panel dims it; a click on the dimming closes the panel.
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { router.closeWorkbenchPanel(agentID: agent.id) }
                        .transition(.opacity)
                        .zIndex(1)
                }
                if open {
                    // A slide of the finished panel (fixed width): only its position changes, so nothing inside
                    // is laid out again. No fade: it would draw the whole panel off screen on every frame.
                    // On top while it leaves too: a view going out of a ZStack loses its place in the order, so the
                    // panel slid out under the chat and seemed to close at once.
                    panel(server: server, agent: agent, width: width, modeWidth: modeWidth, covers: covers)
                        .transition(.move(edge: .trailing))
                        .zIndex(2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .banditoAnimation(BanditoMotion.ease, value: covers)
        }
        .banditoAnimation(WorkbenchLayout.slide, value: open)
        // The ground takes no clicks, so the title band behind the mode gets the empty space (double-click zooms).
        .modeGround()
        // The agent on screen stays the chosen one, so an approval or status change elsewhere does not move it.
        // Not remembered as the last opened agent: only an explicit choice is (Router.selectAgent). Kept under
        // another mode, the chat changes no choice.
        .task(id: "\(server.id.uuidString)|\(agent.id)|\(kept)") {
            guard !kept else { return }
            if let kept = TeamSelection.keptChoice(shown: agent.id), router.selectedAgentID != kept {
                router.selectedAgentID = kept
            }
        }
        // ⌘I, ⌘J and the workbench shortcuts act on the agent on screen.
        .onChange(of: kept ? nil : agent.id, initial: true) { _, id in
            if let id { router.shownAgentID = id }
        }
    }

    private func chat(server: ServerModel, agent: Agent) -> some View {
        // One view for every agent of a server (see `ThreadView`): a switch gives it the new agent. The composer text
        // is kept per agent id in the Router (`Router.drafts`), so it stays with its agent.
        ThreadView(server: server, agent: agent)
            .id(server.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The panel with its resize edge on the left. `width` is the whole width, the edge included. Covering the chat,
    /// it casts a shadow on it.
    private func panel(server: ServerModel, agent: Agent, width: Double, modeWidth: Double, covers: Bool) -> some View {
        HStack(spacing: 0) {
            WorkbenchResizeHandle(
                onDrag: { translation in
                    liveWidth = WorkbenchLayout.draggedWidth(
                        stored: storedWidth, translation: translation, windowWidth: modeWidth)
                        ?? WorkbenchLayout.clampWidth(storedWidth, windowWidth: modeWidth)
                },
                onCommit: { translation in
                    if let dragged = WorkbenchLayout.draggedWidth(
                        stored: storedWidth, translation: translation, windowWidth: modeWidth)
                    {
                        storedWidth = dragged
                    }
                    liveWidth = nil
                },
                onReset: {
                    liveWidth = nil
                    storedWidth = WorkbenchLayout.defaultWidth
                })
            WorkbenchView(server: server, agent: agent)
                .id("\(server.id.uuidString)|\(agent.id)")
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .shadow(color: covers ? Color.black.opacity(0.35) : .clear, radius: 14, x: -4, y: 0)
    }

    /// Under the home, the chat it replaced (`Router.agentBeforeHome`); none when the home came first.
    private func agentBeforeHome(on server: ServerModel) -> Agent? {
        guard let id = router.agentBeforeHome else { return nil }
        return server.agents.first { $0.id == id }
    }

    private func shownAgent(on server: ServerModel) -> Agent? {
        let id = TeamSelection.shownAgentID(
            server: server, selected: router.selectedAgentID, pinned: Set(PinnedAgents().ids))
        return server.agents.first { $0.id == id }
    }
}

/// What a Team mode showed last on screen (see `TeamMode.last`).
@MainActor
final class TeamModeShown {
    var home = false
    var agentID: String?
    var open = false
}

/// The 6 pt edge between the chat and the panel: drag to resize, double-click for the default width. The drag is
/// tracked here; the parent gets the total translation once, when the drag ends.
private struct WorkbenchResizeHandle: View {
    /// Called while the edge moves, with the total horizontal translation so far.
    var onDrag: (Double) -> Void
    /// Called once, when the drag ends, with the total horizontal translation.
    var onCommit: (Double) -> Void
    var onReset: () -> Void

    @GestureState private var dragging = false
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 6)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(dragging ? Color.Bandito.text.opacity(0.3) : Color.Bandito.line)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                #if os(macOS)
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                #endif
            }
            .onDisappear {
                #if os(macOS)
                if hovering { NSCursor.arrow.set() }
                #endif
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in onDrag(Double(value.translation.width)) }
                    .onEnded { value in onCommit(Double(value.translation.width)) }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
    }
}

private struct EmptyTeam: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.currentServer == nil {
            NoServerView(symbol: "bubble.left.and.text.bubble.right")
                .modeGround()
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.Bandito.text3)
                switch app.currentServer?.state {
                case .failed(.keyRejected), .reconnecting where app.currentServer?.refusesKey == true:
                    if let server = app.currentServer { KeyRejectedNotice(server: server) }
                case .failed(let kind):
                    UserFacingErrorView(message: UserFacingError.message(for: kind))
                        .frame(maxWidth: 420)
                    Button(L10n.Banner.retry) {
                        Task { await app.currentServer?.connect() }
                    }
                    .banditoButton(.quiet())
                case .connecting:
                    ProgressView().controlSize(.small)
                default:
                    Text(L10n.Team.pickAgent)
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modeGround()
        }
    }
}
