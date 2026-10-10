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
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// The panel width the person chose; one for the whole app. Kept in range by `WorkbenchLayout.clampWidth`.
    @AppStorage(WorkbenchLayout.widthKey) private var storedWidth = WorkbenchLayout.defaultWidth
    /// The width while the edge is dragged: the panel follows the pointer at once. Written to `storedWidth` only when
    /// the drag ends, so the preference is not written on every pixel.
    @State private var liveWidth: Double?

    var body: some View {
        if router.showsTeamHome, let server = app.currentServer, !server.agents.isEmpty {
            TeamHome(server: server)
                .id(server.id)
                // No chat is on screen: ⌘I, ⌘J and the workbench shortcuts have nothing to act on.
                .onAppear { router.shownAgentID = nil }
        } else if let server = app.currentServer, let agent = shownAgent(on: server) {
            let open = router.workbenchState(for: agent.id).isOpen
            GeometryReader { proxy in
                let modeWidth = Double(proxy.size.width)
                let width = WorkbenchLayout.fittedWidth(stored: liveWidth ?? storedWidth, modeWidth: modeWidth)
                let covers = WorkbenchLayout.coversChat(modeWidth: modeWidth, panelWidth: width)
                // One tree: the chat is always the first child. The panel is placed beside it or over it.
                ZStack(alignment: .trailing) {
                    chat(server: server, agent: agent)
                        .padding(.trailing, open && !covers ? width : 0)
                    if open && covers {
                        // Over the chat the panel dims it; a click on the dimming closes the panel.
                        Color.black.opacity(0.28)
                            .contentShape(Rectangle())
                            .onTapGesture { router.closeWorkbenchPanel(agentID: agent.id) }
                            .transition(.opacity)
                    }
                    if open {
                        panel(server: server, agent: agent, width: width, modeWidth: modeWidth, covers: covers)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .banditoAnimation(BanditoMotion.ease, value: covers)
            }
            .banditoAnimation(BanditoMotion.ease, value: open)
            .background(Color.Bandito.bg)
            // The agent on screen stays the chosen one, so an approval or status change elsewhere does not move it.
            // Not remembered as the last opened agent: only an explicit choice is (Router.selectAgent).
            .task(id: "\(server.id.uuidString)|\(agent.id)") {
                if let kept = TeamSelection.keptChoice(shown: agent.id), router.selectedAgentID != kept {
                    router.selectedAgentID = kept
                }
            }
            // ⌘I, ⌘J and the workbench shortcuts act on the agent on screen.
            .onChange(of: agent.id, initial: true) { _, id in
                router.shownAgentID = id
            }
        } else if let server = app.currentServer, server.state == .connected, server.agents.isEmpty {
            TeamWelcome()
        } else {
            EmptyTeam()
        }
    }

    private func chat(server: ServerModel, agent: Agent) -> some View {
        // Switching agents gives a fresh view. The composer text is not in the view: it is kept per agent id in
        // the Router (`Router.drafts`), so it stays with its agent.
        ThreadView(server: server, agent: agent, inspectorTab: Bindable(router).inspectorTab)
            .id(agent.id)
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

    private func shownAgent(on server: ServerModel) -> Agent? {
        let id = TeamSelection.shownAgentID(
            server: server, selected: router.selectedAgentID, pinned: Set(PinnedAgents().ids))
        return server.agents.first { $0.id == id }
    }
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
                .background(Color.Bandito.bg)
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
            .background(Color.Bandito.bg)
        }
    }
}
