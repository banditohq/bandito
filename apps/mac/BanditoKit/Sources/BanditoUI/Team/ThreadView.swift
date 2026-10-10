import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The thread of one agent: header, the rows, banners and the composer.
struct ThreadView: View {
    var server: ServerModel
    var agent: Agent
    /// Which tab the inspector opens on; the header's schedules button sets it.
    @Binding var inspectorTab: InspectorTab

    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app
    @State private var sendError: UserFacingMessage?
    /// Failures of interrupt, approval and history loading.
    @State private var actionError: UserFacingMessage?
    @State private var loadingOlder = false
    /// Files changed since the last checkpoint; `nil` until loaded or when the server lacks `changes`.
    @State private var changes: ChangesDiff?
    /// Whether the newest message is on screen (the bottom marker is visible).
    @State private var atBottom = true
    /// Files are dragged over the chat.
    @State private var dropTargeted = false
    /// The "down" button shows (see `ThreadScroll.showsJump`), and how many messages came in while the person is above.
    @State private var jumpVisible = false
    @State private var unseen = 0
    /// The scroll position, kept outside the view state: a scroll must not redraw the header and the composer.
    @State private var scroll = ThreadScrollMemory()

    private var thread: AgentThread { server.thread(for: agent.id) }

    /// The tools the agent is running now, by name (a tool row without a result yet).
    private var runningToolNames: [String] {
        let rows: [ToolRow] = thread.items.compactMap { item in
            if case .tool(let row) = item { return row }
            return nil
        }
        return WorkbenchRules.runningToolNames(rows, now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// The agent's details in the workbench, on their details tab (the capsule and the schedules button).
    private func showDetails() {
        inspectorTab = .details
        router.showInWorkbench(.details, agentID: agent.id)
    }

    /// The agent's terminal in the workbench: the one in its folder, or a new one there.
    private func showAgentTerminal() {
        #if os(macOS)
        WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
        #endif
    }

    /// The rows in their scroll view. The width of the thread is reported from the background, so a change of the panel
    /// keeps the bottom on screen (`ThreadWidthKey`).
    private var rows: some View {
        ScrollView {
            ThreadItemsView(
                items: thread.items, server: server, agentID: agent.id, folder: agent.cwd,
                showsLoadEarlier: server.hasMoreHistory[agent.id] == true,
                onLoadEarlier: loadEarlier,
                onError: { actionError = $0 },
                agentName: agent.name,
                primaryRuntime: agent.runtime.rawValue,
                typing: thread.turnRunning && !isStreaming,
                onBottomVisibility: bottomVisibilityChanged)
        }
        .modifier(ThreadDistanceGate { jumpVisible = $0 })
        .background(GeometryReader { geo in
            Color.clear.preference(key: ThreadWidthKey.self, value: geo.size.width)
        })
    }

    /// The newest message came on screen or went off it: the "down" button and the count follow.
    private func bottomVisibilityChanged(_ visible: Bool) {
        atBottom = visible
        if visible {
            unseen = 0
            jumpVisible = false
        } else if !ThreadScroll.hasScrollGeometry {
            jumpVisible = true
        }
    }

    /// The "down" button, when it shows. Kept apart from the scroll chain so the type checker keeps up.
    @ViewBuilder
    private func jumpOverlay(_ proxy: ScrollViewProxy) -> some View {
        if jumpVisible {
            jumpButton {
                withAnimation(.easeOut(duration: BanditoMotion.base)) {
                    proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom)
                }
            }
            .transition(.opacity)
        }
    }

    /// The round "down" button over the thread's bottom right: the number of messages that came in above, if any.
    private func jumpButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .frame(width: 34, height: 34)
                    .background(Color.Bandito.surface2, in: Circle())
                    .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                if unseen > 0 {
                    Text(unseen > 99 ? "99+" : "\(unseen)")
                        .font(BanditoFont.font(size: 10, weight: 600))
                        .monospacedDigit()
                        .foregroundStyle(Color.Bandito.bg)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.Bandito.signal, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
        .banditoButton(.icon(size: 34, label: L10n.Thread.jumpToLatest))
        .help(L10n.Thread.jumpToLatest)
        .padding(.trailing, 22)
        .padding(.bottom, 12)
    }

    /// Shows the thread where it was left: the row that was on top, or the newest message.
    private func restore(_ proxy: ScrollViewProxy) {
        switch ThreadScroll.restoreTarget(router.threadPlaces[agent.id]) {
        case .bottom:
            atBottom = true
            proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom)
        case .row(let id):
            atBottom = false
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// The composer text of this agent, kept by the Router (see `Router.drafts`).
    private var draft: Binding<String> {
        Binding(get: { router.drafts[agent.id] ?? "" }, set: { router.drafts[agent.id] = $0 })
    }

    var body: some View {
        chat
            // Files dragged anywhere over the chat (thread and composer) are attached to this agent.
            .overlay {
                if dropTargeted && canAttach {
                    FileDropHighlight()
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard canAttach else { return false }
                return AttachmentTrays.shared.accept(providers, agentID: agent.id, server: server)
            }
    }

    /// Attaching needs a daemon that lists the `attachments` feature.
    private var canAttach: Bool {
        server.supports("attachments")
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ThreadHeader(
                agent: agent,
                status: thread.status,
                turnRunning: thread.turnRunning,
                changes: server.info?.supports("changes") == true ? changes : nil,
                showsChanges: server.info?.supports("changes") == true,
                showsTerminal: server.supports("terminals"),
                models: server.runtimeModels,
                onInspect: { showDetails() },
                isLead: LeadAgentStore.shared.id(server: server.id.uuidString) == agent.id,
                onChanges: { router.showInWorkbench(.changes, agentID: agent.id) },
                onTerminal: { showAgentTerminal() },
                onTogglePanel: { router.toggleWorkbench() },
                showsBrowserChip: WorkbenchRules.showsBrowserChip(
                    state: router.workbenchState(for: agent.id), runningTools: runningToolNames),
                showsBrowserButton: server.supports("browser"),
                onShowBrowser: { router.showInWorkbench(.browser, agentID: agent.id) })

            ScrollViewReader { proxy in
                rows
                    // A wider or narrower panel changes the rows' height: the bottom stays the bottom.
                    .onPreferenceChange(ThreadWidthKey.self) { _ in
                        guard atBottom else { return }
                        proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom)
                    }
                    // The row on top is remembered (see `ThreadScrollMemory`), so the thread comes back to it.
                    .scrollPosition(id: Binding(get: { scroll.topRowID }, set: { scroll.topRowID = $0 }))
                    // Follow the newest item only while the bottom is on screen: prepending older history, or reading
                    // further up, must not jump to the bottom.
                    .onChange(of: thread.items.last?.id) { _, _ in
                        guard atBottom else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom) }
                    }
                    .onChange(of: thread.items.count) { old, new in
                        if !atBottom {
                            unseen += ThreadScroll.unseenAdded(previousCount: old, currentCount: new)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        jumpOverlay(proxy)
                    }
                    .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: jumpVisible)
                    .onAppear { restore(proxy) }
            }
            if thread.status == .error, let detail = thread.statusDetail {
                Banner(text: detail)
            }
            if let kind = server.lastError {
                FailureBanner(message: UserFacingError.message(for: kind)) {
                    Task { await server.connect() }
                }
            }
            if let sendError {
                FailureBanner(message: sendError) { send() }
            }
            if let actionError {
                FailureBanner(message: actionError) {
                    Task { await server.connect() }
                }
            }
            Composer(
                draft: draft,
                agentName: agent.name,
                running: thread.turnRunning,
                contextFraction: ContextUsage.fraction(tokens: agent.contextTokens, budget: agent.contextBudget),
                agent: agent,
                server: server,
                onSend: send,
                onStop: stop)
                .frame(maxWidth: 780)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.Bandito.bg)
        .task(id: agent.id) {
            await loadHistory()
            await loadChanges()
        }
        .onDisappear {
            router.threadPlaces[agent.id] = ThreadScroll.place(atBottom: atBottom, topRowID: scroll.topRowID)
        }
        // The header names the model from the server's list, so the list is asked once per server, not on opening
        // the inspector. The daemon caches the answer, so a repeat of this request is cheap.
        .task(id: server.id) {
            _ = try? await server.refreshRuntimeModels()
        }
        // Text put here by another screen ("Ask about this place") goes into the composer, once.
        .onChange(of: router.pendingComposerText, initial: true) { _, _ in
            guard let text = router.takeComposerText() else { return }
            router.appendDraft(text, for: agent.id)
        }
        // ⌘R re-reads the thread and the change counts.
        .onChange(of: router.refreshRequests) { _, _ in
            Task {
                await loadHistory()
                await loadChanges()
            }
        }
        // The change counts are refreshed when a turn ends.
        .onChange(of: thread.turnRunning) { wasRunning, isRunning in
            if wasRunning && !isRunning {
                Task { await loadChanges() }
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming? = thread.items.last { return true }
        return false
    }

    private func loadHistory() async {
        do { try await server.loadHistory(agent.id) } catch { actionError = UserFacingError.message(for: error) }
    }

    /// Older history is loaded when its top edge scrolls into view; one page at a time.
    private func loadEarlier() {
        guard !loadingOlder else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do { try await server.loadOlder(agent.id) } catch { actionError = UserFacingError.message(for: error) }
        }
    }

    private func loadChanges() async {
        guard server.info?.supports("changes") == true else {
            changes = nil
            return
        }
        // The counts are a convenience: a failed read keeps the last known numbers.
        if let diff = try? await server.changesDiff(agentID: agent.id) {
            changes = diff
        }
    }

    private func stop() {
        Task {
            do { try await server.interrupt(agent.id) } catch { actionError = UserFacingError.message(for: error) }
        }
    }

    /// Sends the draft of this agent. The id is taken now: a failure puts the text back into the draft of the agent it
    /// was sent to, even when the person has gone to another agent by then.
    private func send() {
        let id = agent.id
        let text = router.takeDraft(for: id)
        // The files that finished uploading go with the text; a failed send leaves them in the tray for a retry.
        let files = AttachmentTray.readyFiles(AttachmentTrays.shared.files(for: id))
        guard !text.isEmpty || !files.isEmpty else { return }
        sendError = nil
        Task {
            do {
                try await server.send(text, to: id, attachments: files)
                AttachmentTrays.shared.removeSent(files, agentID: id)
            } catch {
                sendError = UserFacingError.message(for: error)
                router.restoreDraft(text, for: id)
            }
        }
    }
}

/// The scroll position of one thread view: the row on top. A reference, so that a scroll changes it without a redraw.
@MainActor
final class ThreadScrollMemory {
    var topRowID: String?
}

/// Reports whether the "down" button shows, from the scroll geometry: the distance to the bottom against one screen.
/// Systems without the geometry keep the bottom marker's visibility instead (see `ThreadView`).
private struct ThreadDistanceGate: ViewModifier {
    var onShows: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                ThreadScroll.showsJump(
                    atBottom: false,
                    distance: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height,
                    screen: geometry.containerSize.height)
            } action: { _, shows in
                onShows(shows)
            }
        } else {
            content
        }
    }
}

/// The width of the thread, reported up so that a change of width keeps the bottom on screen.
private struct ThreadWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The rows of a thread. Separate from the scroll view so it can be rendered on its own (snapshots, previews).
struct ThreadItemsView: View {
    var items: [ThreadItem]
    var server: ServerModel
    var agentID = ""
    var folder: String?
    var showsLoadEarlier = false
    var onLoadEarlier: () -> Void = {}
    var onError: (UserFacingMessage) -> Void = { _ in }
    var agentName = ""
    var primaryRuntime = ""
    /// Shows the typing indicator after the last row while a turn runs.
    var typing = false
    /// Whether the bottom marker (the newest message) is on screen.
    var onBottomVisibility: (Bool) -> Void = { _ in }

    var body: some View {
        let rows = ThreadRows.build(items)
        LazyVStack(alignment: .leading, spacing: 12) {
            if showsLoadEarlier {
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: onLoadEarlier)
            }
            ForEach(rows) { row in
                ThreadRowView(
                    row: row, agentName: agentName, primaryRuntime: primaryRuntime, server: server,
                    agentID: agentID, folder: folder, onError: onError)
                    .banditoRise()
            }
            if typing {
                TypingIndicator(activity: AgentActivity.current(in: items), since: AgentActivity.turnStart(in: items))
            }
            Color.clear.frame(height: 1).id(ThreadScroll.bottomID)
                .onAppear { onBottomVisibility(true) }
                .onDisappear { onBottomVisibility(false) }
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

/// A failure in the thread: the sentence from `UserFacingError`, with "Повторить" when `onRetry` is given.
private struct FailureBanner: View {
    let message: UserFacingMessage
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.Bandito.danger)
            UserFacingErrorView(message: message, onRetry: onRetry)
            Spacer()
        }
        .padding(12)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

private struct Banner: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.Bandito.danger)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.Bandito.text).textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
