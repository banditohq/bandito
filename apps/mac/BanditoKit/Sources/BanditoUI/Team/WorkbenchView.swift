import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The workbench panel beside the chat (Team mode): the agent's tabs on top, the selected tab below. The terminal,
/// the browser, files, the changes and the agent's details sit here, so the person does not leave the chat for them.
///
/// One tree, always: two panes stacked in one column. When the panel is not split, the second pane is collapsed to
/// zero height and hidden, so the first pane keeps its place in the tree.
struct WorkbenchView: View {
    var server: ServerModel
    var agent: Agent

    @Environment(Router.self) private var router
    /// The top pane's share of the height when split; one for the whole app.
    @AppStorage(WorkbenchLayout.splitKey) private var storedSplit = WorkbenchLayout.defaultSplit

    private var state: WorkbenchState { router.workbenchState(for: agent.id) }

    var body: some View {
        GeometryReader { proxy in
            let split = state.isSplit
            let divider = split ? WorkbenchSplitHandle.height : 0
            let share = WorkbenchLayout.clampSplit(storedSplit)
            let top = split ? max(0, (proxy.size.height - divider) * share) : proxy.size.height
            let compact = proxy.size.width < Self.compactBelow
            VStack(spacing: 0) {
                pane(0, showsPanelActions: true, compact: compact)
                    .frame(height: top)
                    .id(0)
                WorkbenchSplitHandle(
                    share: share,
                    height: proxy.size.height,
                    onCommit: { translation in
                        storedSplit = WorkbenchLayout.clampSplit(share + translation / max(proxy.size.height, 1))
                    },
                    onReset: { storedSplit = WorkbenchLayout.defaultSplit })
                    .frame(height: divider)
                    .opacity(split ? 1 : 0)
                    .allowsHitTesting(split)
                pane(1, showsPanelActions: false, compact: compact)
                    .frame(maxHeight: split ? .infinity : 0)
                    .clipped()
                    .allowsHitTesting(split)
                    .accessibilityHidden(!split)
                    .id(1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface1)
        .banditoAnimation(BanditoMotion.ease, value: state.isSplit)
        // A failure of a panel action (a terminal that did not open), over the top of the panel until dismissed.
        .overlay(alignment: .top) {
            if let notice = router.workbenchNotice(for: agent.id) {
                HStack(alignment: .top, spacing: 8) {
                    UserFacingErrorView(message: notice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        router.setWorkbenchNotice(nil, for: agent.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .banditoButton(.icon(size: 24, label: L10n.Common.close))
                    .help(L10n.Common.close)
                }
                .padding(10)
                .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
            }
        }
    }

    /// Below this width the panel's header drops the split button.
    static let compactBelow: CGFloat = 420

    /// One pane: its tab strip, and the content of its selected tab. A click anywhere in it focuses it. An index the
    /// state does not have (the second pane while not split) shows an empty pane, which is hidden.
    private func pane(_ index: Int, showsPanelActions: Bool, compact: Bool) -> some View {
        let pane = WorkbenchRules.pane(index, of: state)
        let focused = state.isSplit && state.focusedPane == index
        return VStack(spacing: 0) {
            WorkbenchHeader(
                server: server, agent: agent, pane: index, showsPanelActions: showsPanelActions, compact: compact)
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            if let tab = pane.selected {
                WorkbenchTabContent(
                    server: server, agent: agent, tab: tab,
                    place: TerminalDisplayOwner.workbench(agentID: agent.id, pane: index))
                    .id(tab)
            } else {
                WorkbenchEmpty(server: server, agent: agent, pane: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if focused {
                Rectangle().fill(Color.Bandito.text.opacity(0.22)).frame(height: 2)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            if state.isSplit { router.focusWorkbenchPane(index, agentID: agent.id) }
        })
    }
}

/// The 6 pt divider between the two panes: drag to change the share, double-click for the even split. The drag
/// is tracked here; the parent gets the total translation once, when the drag ends.
private struct WorkbenchSplitHandle: View {
    static let height: CGFloat = 6

    /// The top pane's share now, and the height of the whole panel.
    var share: Double
    var height: CGFloat
    /// Called once, when the drag ends, with the total vertical translation.
    var onCommit: (Double) -> Void
    var onReset: () -> Void

    @GestureState private var dragging = false
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(height: Self.height)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(dragging ? Color.Bandito.text.opacity(0.3) : Color.Bandito.line)
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                #if os(macOS)
                if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
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
                    .onEnded { value in
                        // A click without a move changes nothing.
                        guard abs(value.translation.height) >= 1 else { return }
                        onCommit(Double(value.translation.height))
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
    }
}

/// The tab strip and the panel's buttons: add a tab, close the panel. The strip scrolls sideways when the tabs
/// do not fit; each tab keeps its name on one line.
private struct WorkbenchHeader: View {
    var server: ServerModel
    var agent: Agent
    /// The pane whose tabs the strip shows.
    var pane: Int
    /// Split and close belong to the panel as a whole: only the top pane's header has them.
    var showsPanelActions: Bool
    /// A narrow panel: the split button is dropped, the tabs and the close button stay.
    var compact = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    private var state: WorkbenchState { router.workbenchState(for: agent.id) }
    // The second pane stays in the view tree with no height while the panel is not split, so its index can be past
    // the end: it reads as an empty pane then.
    private var paneState: WorkbenchPane { WorkbenchRules.pane(pane, of: state) }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(paneState.tabs, id: \.self) { tab in
                        WorkbenchTabButton(
                            title: title(for: tab), tab: tab, selected: tab == paneState.selected,
                            agentID: agent.id, paneIndex: pane, paneCount: state.panes.count)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)
            addMenu
            if showsPanelActions && !compact {
                Button {
                    router.toggleWorkbenchSplit(agentID: agent.id)
                } label: {
                    Image(systemName: "square.split.1x2")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .banditoButton(.icon(size: 28, label: state.isSplit ? L10n.Workbench.unsplit : L10n.Workbench.split))
                .help(state.isSplit ? L10n.Workbench.unsplit : L10n.Workbench.split)
                .fixedSize()
                Button {
                    router.closeWorkbenchPanel(agentID: agent.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .banditoButton(.icon(size: 28, label: L10n.Workbench.closePanel))
                .help(L10n.Workbench.closePanel)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }

    /// Opens `tab` in this pane: the pane is focused first, so the tab lands here.
    private func open(_ tab: WorkbenchTab) {
        router.focusWorkbenchPane(pane, agentID: agent.id)
        router.showInWorkbench(tab, agentID: agent.id)
    }

    private var addMenu: some View {
        Menu {
            Button(L10n.Workbench.newTerminal) {
                router.focusWorkbenchPane(pane, agentID: agent.id)
                openAgentTerminal()
            }
            .disabled(!server.supports("terminals"))
            Button(L10n.Workbench.browser) { open(.browser) }
                .disabled(!server.supports("browser"))
            Button(L10n.Workbench.changes) { open(.changes) }
                .disabled(server.info?.supports("changes") != true)
            Button(L10n.Workbench.details) { open(.details) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .banditoButton(.icon(size: 28, label: L10n.Workbench.add))
        .help(L10n.Workbench.add)
        .fixedSize()
    }

    private func title(for tab: WorkbenchTab) -> String {
        switch tab {
        case .details: agent.name
        case .terminal(let id): terminalTitle(id)
        case .browser: L10n.Workbench.browser
        case .file(let path): tab.fileName ?? path
        case .changes: L10n.Workbench.changes
        }
    }

    private func terminalTitle(_ id: String) -> String {
        #if os(macOS)
        app.terminalController(for: server).session(for: id)?.info.title ?? L10n.Workbench.terminal
        #else
        L10n.Workbench.terminal
        #endif
    }

    /// The agent's terminal: the one already open in its folder, else a new one there. The same session as in
    /// Terminals mode.
    private func openAgentTerminal() {
        #if os(macOS)
        WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
        #endif
    }
}

/// One tab of the strip: the name, and a close button that shows on the selected or hovered tab.
private struct WorkbenchTabButton: View {
    var title: String
    var tab: WorkbenchTab
    var selected: Bool
    var agentID: String
    var paneIndex: Int
    var paneCount: Int

    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                router.selectWorkbenchTab(tab, agentID: agentID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 12, weight: .medium))
                    Text(title)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .frame(height: 30)
            }
            .banditoButton(.row(cornerRadius: 8, hoverOpacity: 0.06))
            .help(title)

            Button {
                router.closeWorkbenchTab(tab, agentID: agentID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(width: 18, height: 18)
            }
            .banditoButton(.icon(size: 18, label: L10n.Workbench.closeTab))
            .help(L10n.Workbench.closeTab)
            .opacity(selected || hovering ? 1 : 0)
            .allowsHitTesting(selected || hovering)
            .padding(.trailing, 4)
        }
        .background(
            selected ? Color.Bandito.text.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            if paneCount > 1 {
                Button(L10n.Workbench.moveToOtherPane) {
                    router.moveWorkbenchTab(tab, toPane: paneIndex == 0 ? 1 : 0, agentID: agentID)
                }
            }
            Button(L10n.Workbench.closeTab) {
                router.closeWorkbenchTab(tab, agentID: agentID)
            }
        }
    }
}

/// The content of one tab. Details are the inspector, without its own close button: the panel closes.
private struct WorkbenchTabContent: View {
    var server: ServerModel
    var agent: Agent
    var tab: WorkbenchTab
    /// The place of this pane, for the terminal view's owner (see `TerminalDisplayOwner`).
    var place: String

    @Environment(Router.self) private var router

    var body: some View {
        switch tab {
        case .details:
            InspectorView(server: server, agent: agent, tab: Bindable(router).inspectorTab, onClose: nil)
        case .terminal(let id):
            #if os(macOS)
            WorkbenchTerminal(server: server, agent: agent, sessionID: id, place: place)
            #else
            EmptyView()
            #endif
        case .browser:
            #if os(macOS)
            WorkbenchBrowser(server: server)
            #else
            EmptyView()
            #endif
        case .file(let path):
            WorkbenchFileTab(server: server, agentID: agent.id, path: path)
        case .changes:
            ChangesContent(agentID: agent.id) {
                router.closeWorkbenchTab(.changes, agentID: agent.id)
            }
        }
    }
}

/// A panel with no tab on show: says what the panel is for, and offers the usual first steps.
private struct WorkbenchEmpty: View {
    var server: ServerModel
    var agent: Agent
    /// The pane this empty state is in: the tabs it offers open there.
    var pane: Int

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Workbench.emptyTitle)
                .font(BanditoFont.font(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Text(L10n.Workbench.emptyHint)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if server.supports("terminals") {
                    Button(L10n.Workbench.newTerminal) {
                        router.focusWorkbenchPane(pane, agentID: agent.id)
                        #if os(macOS)
                        WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
                        #endif
                    }
                    .banditoButton(.quiet())
                    .lineLimit(1)
                    .fixedSize()
                }
                Button(L10n.Workbench.details) {
                    router.focusWorkbenchPane(pane, agentID: agent.id)
                    router.showInWorkbench(.details, agentID: agent.id)
                }
                .banditoButton(.quiet())
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
/// Opening the agent's terminal in the panel. The terminals are the server's, shared with Terminals mode.
@MainActor
enum WorkbenchTerminals {
    /// Shows the terminal of the agent: the newest one open in the agent's folder, else a new terminal there.
    static func showAgentTerminal(server: ServerModel, agent: Agent, app: AppModel, router: Router) {
        let controller = app.terminalController(for: server)
        if let existing = inFolder(agent.cwd, of: controller) {
            router.showInWorkbench(.terminal(sessionID: existing), agentID: agent.id)
            return
        }
        // A request while one is opening is dropped: one agent opens one terminal at a time.
        guard router.beginOpeningTerminal(agentID: agent.id) else { return }
        Task {
            defer { router.endOpeningTerminal(agentID: agent.id) }
            await controller.start()
            controller.clearNotice()
            // The id comes from the open itself. On failure the panel says so; no other session is shown in its place.
            if let opened = await controller.openNew(cwd: agent.cwd, afterFocused: false) {
                router.showInWorkbench(.terminal(sessionID: opened), agentID: agent.id)
            } else {
                router.setWorkbenchNotice(
                    controller.notice ?? UserFacingMessage(text: L10n.Workbench.terminalFailed), for: agent.id)
            }
        }
    }

    /// The running session in `folder` that was made last, if any.
    private static func inFolder(_ folder: String, of controller: TerminalController) -> String? {
        controller.sessions.values
            .filter { $0.info.cwd == folder && $0.exit == nil }
            .max { $0.info.createdAt < $1.info.createdAt }?
            .id
    }
}

/// A terminal of the server in a workbench tab: the same pane as in Terminals mode. Closing a running one asks first,
/// as in Terminals mode.
private struct WorkbenchTerminal: View {
    var server: ServerModel
    var agent: Agent
    var sessionID: String
    var place: String

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// The running terminal the person is asked about before it is closed.
    @State private var closeCandidate: String?

    var body: some View {
        let controller = app.terminalController(for: server)
        Group {
            // The terminal view sits in one place only: this pane draws it while it is the owner. Otherwise the
            // place that owns it is named, and the pane can take it over.
            if let session = controller.session(for: sessionID), controller.display.isOwner(place) {
                TerminalPaneView(
                    controller: controller, session: session, isFocused: true,
                    requestClose: { requestClose($0, controller: controller) })
            } else if controller.session(for: sessionID) != nil {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.Bandito.text3)
                    Text(controller.display.isOwner(TerminalDisplayOwner.terminals)
                        ? L10n.Workbench.terminalElsewhere : L10n.Workbench.terminalInOtherPane)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .multilineTextAlignment(.center)
                    Button(L10n.Workbench.showHere) {
                        controller.claimDisplay(place)
                    }
                    .banditoButton(.quiet())
                    .lineLimit(1)
                    .fixedSize()
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Text(L10n.Workbench.terminalEnded)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    // The closed tab is replaced by a new terminal in the agent's folder (or the running one there).
                    Button(L10n.Workbench.openNewTerminal) {
                        router.closeWorkbenchTab(.terminal(sessionID: sessionID), agentID: agent.id)
                        WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
                    }
                    .banditoButton(.quiet())
                    .lineLimit(1)
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x0E0C0B))
        .task(id: server.id) {
            await controller.start()
        }
        .onAppear { controller.claimDisplay(place) }
        .onDisappear { controller.releaseDisplay(place) }
        .confirmationDialog(
            L10n.Terminals.ConfirmClose.title,
            isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Terminals.ConfirmClose.end, role: .destructive) {
                if let id = closeCandidate {
                    Task { await controller.close(id) }
                }
            }
            Button(L10n.Terminals.ConfirmClose.cancel, role: .cancel) {}
        }
    }

    /// Closes at once when the process has ended; otherwise asks first.
    private func requestClose(_ id: String, controller: TerminalController) {
        if let info = controller.session(for: id)?.info, case .running = info.state {
            closeCandidate = id
        } else {
            Task { await controller.close(id) }
        }
    }
}

/// The browser of the server in a workbench tab: the same model as in Browser mode.
private struct WorkbenchBrowser: View {
    var server: ServerModel

    var body: some View {
        let model = BrowserStore.shared.model(for: server)
        BrowserMainArea(model: model)
            .task(id: server.id) {
                model.attach()
            }
            .onDisappear {
                model.detach()
            }
    }
}
#endif
