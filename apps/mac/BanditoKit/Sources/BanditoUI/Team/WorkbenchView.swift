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
    /// The top pane's share while the divider is dragged: the panes follow the pointer at once. Written to
    /// `storedSplit` only when the drag ends.
    @State private var liveSplit: Double?

    private var state: WorkbenchState { router.workbenchState(for: agent.id) }

    var body: some View {
        GeometryReader { proxy in
            let split = state.isSplit
            let divider = split ? WorkbenchSplitHandle.height : 0
            let share = WorkbenchLayout.clampSplit(liveSplit ?? storedSplit)
            let top = split ? max(0, (proxy.size.height - divider) * share) : proxy.size.height
            let panelWidth = Double(proxy.size.width)
            VStack(spacing: 0) {
                pane(0, showsPanelActions: true, panelWidth: panelWidth)
                    .frame(height: top)
                    .id(0)
                WorkbenchSplitHandle(
                    share: share,
                    height: proxy.size.height,
                    onDrag: { translation in
                        liveSplit = WorkbenchLayout.splitAfterDrag(
                            stored: storedSplit, translation: translation, height: proxy.size.height)
                    },
                    onCommit: { translation in
                        storedSplit = WorkbenchLayout.splitAfterDrag(
                            stored: storedSplit, translation: translation, height: proxy.size.height)
                        liveSplit = nil
                    },
                    onReset: {
                        liveSplit = nil
                        storedSplit = WorkbenchLayout.defaultSplit
                    })
                    .frame(height: divider)
                    .opacity(split ? 1 : 0)
                    .allowsHitTesting(split)
                pane(1, showsPanelActions: false, panelWidth: panelWidth)
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

    /// One pane: its tab strip, and the content of its selected tab. A click anywhere in it focuses it. An index the
    /// state does not have (the second pane while not split) shows an empty pane, which is hidden.
    private func pane(_ index: Int, showsPanelActions: Bool, panelWidth: Double) -> some View {
        let pane = WorkbenchRules.pane(index, of: state)
        let focused = state.isSplit && state.focusedPane == index
        return VStack(spacing: 0) {
            WorkbenchHeader(
                server: server, agent: agent, pane: index, showsPanelActions: showsPanelActions, panelWidth: panelWidth)
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
    /// Called while the divider moves, with the total vertical translation so far.
    var onDrag: (Double) -> Void
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
                    .onChanged { value in onDrag(Double(value.translation.height)) }
                    .onEnded { value in onCommit(Double(value.translation.height)) }
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
    /// The whole panel's width. Narrow, the inactive tabs drop their names (see `WorkbenchLayout.showsTabTitle`).
    var panelWidth: Double

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// The running terminal the person is asked about before its session ends (from a tab's menu).
    @State private var endCandidate: String?

    private var state: WorkbenchState { router.workbenchState(for: agent.id) }
    // The second pane stays in the view tree with no height while the panel is not split, so its index can be past
    // the end: it reads as an empty pane then.
    private var paneState: WorkbenchPane { WorkbenchRules.pane(pane, of: state) }

    var body: some View {
        HStack(spacing: 6) {
            // The strip takes what the buttons leave and scrolls sideways; the buttons never leave the panel.
            // The chosen tab is scrolled into view, so a tab opened from elsewhere is never hidden past the edge.
            ScrollViewReader { strip in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(paneState.tabs, id: \.self) { tab in
                        let selected = tab == paneState.selected
                        WorkbenchTabButton(
                            title: title(for: tab), help: help(for: tab), tab: tab,
                            selected: selected,
                            showsTitle: WorkbenchLayout.showsTabTitle(selected: selected, panelWidth: panelWidth),
                            agentID: agent.id, paneIndex: pane, paneCount: state.panes.count,
                            onEndSession: { requestEnd($0) },
                            rawName: rawName(for: tab),
                            onRename: { id, name in
                                #if os(macOS)
                                Task { await app.terminalController(for: server).rename(id, to: name) }
                                #endif
                            })
                        .id(tab)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: paneState.selected, initial: true) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: BanditoMotion.fast)) { strip.scrollTo(selected) }
            }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(0)
            addMenu
                .layoutPriority(1)
            if showsPanelActions {
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
                .layoutPriority(1)
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
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .confirmationDialog(
            L10n.Terminals.ConfirmClose.title,
            isPresented: Binding(get: { endCandidate != nil }, set: { if !$0 { endCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Terminals.ConfirmClose.end, role: .destructive) {
                if let id = endCandidate {
                    Task { await app.terminalController(for: server).close(id) }
                }
            }
            Button(L10n.Terminals.ConfirmClose.cancel, role: .cancel) {}
        }
    }

    /// Ends a terminal's session from its tab. A running process is asked about first, as in Terminals mode.
    private func requestEnd(_ id: String) {
        #if os(macOS)
        let controller = app.terminalController(for: server)
        if let info = controller.session(for: id)?.info, case .running = info.state {
            endCandidate = id
        } else {
            Task { await controller.close(id) }
        }
        #endif
    }

    /// Opens `tab` in this pane: the pane the person pressed in, so the tab lands here.
    private func open(_ tab: WorkbenchTab) {
        router.showInWorkbench(tab, agentID: agent.id, pane: pane)
    }

    private var addMenu: some View {
        Menu {
            Button(L10n.Workbench.newTerminal) {
                openNewTerminal()
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

    /// A terminal's name as the person gave it; nil for other tabs and for a terminal not here.
    private func rawName(for tab: WorkbenchTab) -> String? {
        #if os(macOS)
        if case .terminal(let id) = tab {
            return app.terminalController(for: server).session(for: id)?.info.title
        }
        #endif
        return nil
    }

    /// The tooltip of a tab: a terminal's folder, which the name does not show. Other tabs have none.
    private func help(for tab: WorkbenchTab) -> String? {
        #if os(macOS)
        if case .terminal(let id) = tab {
            return app.terminalController(for: server).session(for: id)?.info.cwd
        }
        #endif
        return nil
    }

    private func terminalTitle(_ id: String) -> String {
        #if os(macOS)
        app.terminalController(for: server).displayTitle(id) ?? L10n.Workbench.terminal
        #else
        L10n.Workbench.terminal
        #endif
    }

    /// A new terminal in the agent's folder, shown in this pane. Each press makes one: several terminals can share a pane.
    private func openNewTerminal() {
        #if os(macOS)
        WorkbenchTerminals.openNewTerminal(server: server, agent: agent, app: app, router: router, pane: pane)
        #endif
    }
}

/// One tab of the strip: the name, and a close button that shows on the selected or hovered tab.
private struct WorkbenchTabButton: View {
    var title: String
    /// The tooltip of the tab, if it has one (a terminal's folder).
    var help: String?
    var tab: WorkbenchTab
    var selected: Bool
    /// Whether the name shows; without it the tab is its icon, and the name is in the tooltip.
    var showsTitle: Bool
    var agentID: String
    var paneIndex: Int
    var paneCount: Int
    /// Ends the session of a terminal tab (its menu item). Called with the terminal's id.
    var onEndSession: (String) -> Void
    /// A terminal's name as the person gave it (the field's start), and the rename of a terminal (called with the new name).
    var rawName: String?
    var onRename: (String, String) -> Void

    @Environment(Router.self) private var router
    @State private var hovering = false
    /// The tab is a name field while a terminal is renamed.
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var terminalID: String? {
        if case .terminal(let id) = tab { return id }
        return nil
    }

    /// The field starts with the name as the person gave it, and the rename is the same as in Terminals mode.
    private func startRename() {
        draft = rawName ?? title
        renaming = true
        nameFocused = true
    }

    private func commitRename(_ id: String) {
        renaming = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != rawName else { return }
        onRename(id, name)
    }

    /// With the name shown, the tooltip is the folder (terminals). Without it, the name comes first.
    private var tooltip: String {
        if showsTitle { return help ?? "" }
        return [title, help].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 2) {
            if renaming, let terminalID {
                TextField(L10n.Terminals.rename, text: $draft)
                    .banditoField()
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .frame(width: 170)
                    .focused($nameFocused)
                    .onSubmit { commitRename(terminalID) }
                    .onExitCommand { renaming = false }
            } else {
                Button {
                    router.selectWorkbenchTab(tab, agentID: agentID)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .medium))
                        if showsTitle {
                            // A long name is cut at the end; the whole name is the tooltip.
                            Text(title)
                                .font(BanditoFont.text(size: 12.5, weight: 500))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 180, alignment: .leading)
                        }
                    }
                    .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                    .padding(.leading, 9)
                    .padding(.trailing, showsTitle ? 6 : 9)
                    .frame(height: 30)
                }
                .banditoButton(.row(cornerRadius: 8, hoverOpacity: 0.06))
                .help(tooltip)
                .accessibilityLabel(title)

                Button {
                    router.closeWorkbenchTab(tab, agentID: agentID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text3)
                        .frame(width: 18, height: 18)
                }
                .banditoButton(.icon(size: 18, label: L10n.Workbench.closeTab))
                // Its name is for VoiceOver only: a tooltip here would take the hover from the tab.
                .accessibilityLabel(L10n.Workbench.closeTab)
                .opacity(selected || hovering ? 1 : 0)
                .allowsHitTesting(selected || hovering)
                .padding(.trailing, 4)
            }
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
            if let terminalID {
                Button(L10n.Workbench.rename) { startRename() }
                Button(L10n.Workbench.endSession) { onEndSession(terminalID) }
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
                .font(BanditoFont.text(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Text(L10n.Workbench.emptyHint)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if server.supports("terminals") {
                    Button(L10n.Workbench.newTerminal) {
                        #if os(macOS)
                        WorkbenchTerminals.openNewTerminal(
                            server: server, agent: agent, app: app, router: router, pane: pane)
                        #endif
                    }
                    .banditoButton(.quiet())
                    .lineLimit(1)
                    .fixedSize()
                }
                if server.supports("browser") {
                    Button(L10n.Workbench.browser) {
                        router.showInWorkbench(.browser, agentID: agent.id, pane: pane)
                    }
                    .banditoButton(.quiet())
                    .lineLimit(1)
                    .fixedSize()
                }
                Button(L10n.Workbench.details) {
                    router.showInWorkbench(.details, agentID: agent.id, pane: pane)
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
    /// Shows the terminal of the agent: the newest running one in the agent's folder, else a new terminal there.
    static func showAgentTerminal(server: ServerModel, agent: Agent, app: AppModel, router: Router) {
        open(server: server, agent: agent, app: app, router: router, pane: nil, reuseExisting: true)
    }

    /// A new terminal in the agent's folder, shown in pane `pane`. Unlike `showAgentTerminal`, it never reuses the
    /// terminal already open there: each "+" makes one.
    static func openNewTerminal(server: ServerModel, agent: Agent, app: AppModel, router: Router, pane: Int) {
        open(server: server, agent: agent, app: app, router: router, pane: pane, reuseExisting: false)
    }

    private static func open(
        server: ServerModel, agent: Agent, app: AppModel, router: Router, pane: Int?, reuseExisting: Bool
    ) {
        let controller = app.terminalController(for: server)
        // A request while one is opening is dropped: one agent opens one terminal at a time.
        guard router.beginOpeningTerminal(agentID: agent.id) else { return }
        Task {
            defer { router.endOpeningTerminal(agentID: agent.id) }
            // The server's sessions are read first: until then the controller has none, and a terminal would be opened
            // again each time the agent's terminal is asked for.
            await controller.start()
            controller.clearNotice()
            @MainActor func show(_ tab: WorkbenchTab) {
                if let pane {
                    router.showInWorkbench(tab, agentID: agent.id, pane: pane)
                } else {
                    router.showInWorkbench(tab, agentID: agent.id)
                }
            }
            if reuseExisting, let existing = inFolder(agent.cwd, of: controller) {
                show(.terminal(sessionID: existing))
                return
            }
            // The id comes from the open itself. On failure the panel says so; no other session is shown in its place.
            if let opened = await controller.openNew(cwd: agent.cwd, afterFocused: false) {
                show(.terminal(sessionID: opened))
            } else {
                router.setWorkbenchNotice(
                    controller.notice ?? UserFacingMessage(text: L10n.Workbench.terminalFailed), for: agent.id)
            }
        }
    }

    /// The running session in `folder` that was made last, if any.
    private static func inFolder(_ folder: String, of controller: TerminalController) -> String? {
        let running = controller.sessions.values.filter { $0.exit == nil }.map(\.info)
        return TerminalNames.newestSession(in: folder, among: running)?.id
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
                    requestClose: { requestClose($0, controller: controller) }, compact: true)
            } else if controller.session(for: sessionID) != nil {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.Bandito.text3)
                    Text(controller.display.isOwner(TerminalDisplayOwner.terminals)
                        ? L10n.Workbench.terminalElsewhere : L10n.Workbench.terminalInOtherPane)
                        .font(BanditoFont.text(size: 13, weight: 400))
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
                        .font(BanditoFont.text(size: 13, weight: 400))
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
    @Environment(Router.self) private var router

    var body: some View {
        let model = BrowserStore.shared.model(for: server)
        // The same page, the same tab: Browser mode shows the model the panel shows.
        BrowserMainArea(model: model, onOpenFullscreen: { router.select(mode: .browser) })
            .task(id: server.id) {
                model.attach()
            }
            .onDisappear {
                model.detach()
            }
    }
}
#endif
