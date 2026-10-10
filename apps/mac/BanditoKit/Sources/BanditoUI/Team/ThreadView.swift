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
    /// A row to bring on screen (a quoted message, a form), and the row that flashes after it.
    @State private var scrollRequest: ScrollRequest?
    @State private var highlightedID: String?
    /// Counts the requests to scroll to the bottom (the send, the "down" button); the scroll chain answers each one.
    @State private var bottomRequest = 0
    /// The id of the first item drawn. Items older than it are not drawn until the top is reached (see
    /// `ThreadScroll.windowSize`). Kept, not computed from the end, so appended items do not slide the window.
    @State private var windowStartID: String?
    @State private var jumpTask: Task<Void, Never>?
    @State private var highlightTask: Task<Void, Never>?
    private var replyDrafts: ReplyDrafts { ReplyDrafts.shared }

    /// The items drawn: from the start of the window to the newest.
    private var shownItems: [ThreadItem] {
        let items = thread.items
        let start = ThreadScroll.windowStart(ids: items.map(\.id), startID: windowStartID)
        return start == 0 ? items : Array(items[start...])
    }

    private var shownRowIDs: [String] { ThreadRows.build(shownItems).map(\.id) }

    /// At the bottom, the window does not grow without a limit: rows far above the screen are dropped.
    private func slideWindow() {
        guard atBottom else { return }
        let ids = thread.items.map(\.id)
        let start = ThreadScroll.windowStart(ids: ids, startID: windowStartID)
        let slid = ThreadScroll.slidStart(count: ids.count, start: start, atBottom: true)
        if slid != start { windowStartID = ids[slid] }
    }

    /// Pins the window's start to an item once there are items, or when the pinned one is gone.
    private func pinWindow() {
        let items = thread.items
        guard !items.isEmpty else { return }
        if let windowStartID, items.contains(where: { $0.id == windowStartID }) { return }
        windowStartID = items[ThreadScroll.windowStart(ids: items.map(\.id), startID: nil)].id
    }

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

    /// The rows in their scroll view. Plain stack, not a lazy one: the heights are exact, so rows do not move under a
    /// still pointer while estimates are redone (that fed a loop of hover and layout). Where the rows are is read
    /// from their geometry into `scroll`, a reference that does not redraw the view.
    private func rows(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            ThreadItemsView(
                items: shownItems, server: server, agentID: agent.id, folder: agent.cwd,
                onError: { actionError = $0 },
                agentName: agent.name,
                primaryRuntime: agent.runtime.rawValue,
                chat: chat,
                typing: thread.turnRunning && !isStreaming,
                onRowSpan: { [scroll] id, span in scroll.rowSpans[id] = span },
                onContent: { offset, height in contentChanged(offset: offset, height: height, proxy) })
        }
        .coordinateSpace(name: ThreadScroll.scrollSpace)
        .modifier(ThreadGeometryGate { old, new in scrollGeometryChanged(old, new, proxy) })
        .onGeometryChange(for: Double.self) { Double($0.size.height).rounded() } action: { height in
            scroll.containerHeight = height
            legacyMetricsChanged(proxy)
        }
    }

    /// The content moved or changed height (reported from its geometry): the top is watched for older rows, and where
    /// the scroll geometry is not known (macOS 14) the metrics are built from it.
    private func contentChanged(offset: Double, height: Double, _ proxy: ScrollViewProxy) {
        scroll.offset = offset
        scroll.contentHeight = height
        let near = ThreadScroll.nearTop(offset: offset)
        if near != scroll.nearTop {
            scroll.nearTop = near
            if !near { scroll.topRetried = false }
            if near { DispatchQueue.main.async { topReached() } }
        }
        legacyMetricsChanged(proxy)
    }

    private func legacyMetricsChanged(_ proxy: ScrollViewProxy) {
        guard !ThreadScroll.hasScrollGeometry, scroll.containerHeight > 0 else { return }
        let new = ThreadScrollMetrics(
            offset: scroll.offset, contentHeight: scroll.contentHeight, height: scroll.containerHeight)
        guard new != scroll.metrics else { return }
        let old = scroll.metrics
        scroll.metrics = new
        scrollGeometryChanged(old, new, proxy)
    }

    /// The top of the thread came near: draw older rows that are loaded, else read older history.
    private func topReached() {
        guard scroll.alive, !thread.items.isEmpty else { return }
        let ids = thread.items.map(\.id)
        let start = ThreadScroll.windowStart(ids: ids, startID: windowStartID)
        if start > 0 {
            // No row on top known: the window is not changed blindly.
            keepTopRow()
            guard scroll.anchorRow != nil else { return }
            windowStartID = ids[ThreadScroll.widenedStart(from: start)]
        } else if server.hasMoreHistory[agent.id] == true {
            loadEarlier()
        }
    }

    /// The index of the first item to draw so that the row `id` is among the rows, searching upward from the window's
    /// start in steps; nil when no loaded item gives that row.
    private func startRevealing(row id: String) -> Int? {
        let items = thread.items
        var start = ThreadScroll.windowStart(ids: items.map(\.id), startID: windowStartID)
        while start > 0 {
            start = max(0, start - 50)
            if ThreadRows.build(Array(items[start...])).contains(where: { $0.id == id }) { return start }
        }
        return nil
    }

    /// Notes the row on top, so that rows put above it do not move it: it is scrolled back to once they are drawn.
    private func keepTopRow() {
        scroll.anchorRow = ThreadScroll.topRow(
            spans: scroll.rowSpans, offset: scroll.offset, valid: Set(shownRowIDs))
        if scroll.anchorRow != nil { scroll.skipFollow = true }
    }

    /// Writes the flags only when they really change: a scroll reports many times, the flags rarely change.
    private func setAtBottom(_ value: Bool) {
        if atBottom != value { atBottom = value }
        if value && unseen != 0 { unseen = 0 }
    }

    private func setJumpVisible(_ value: Bool) {
        if jumpVisible != value { jumpVisible = value }
    }

    /// The scroll geometry changed (macOS 15 and later): the bottom, the "down" button and the follow of the bottom
    /// all follow from the measured distance, never from the position of a marker.
    private func scrollGeometryChanged(_ old: ThreadScrollMetrics?, _ new: ThreadScrollMetrics, _ proxy: ScrollViewProxy) {
        let at = ThreadScroll.atBottom(was: atBottom, old: old, new: new)
        setAtBottom(at)
        setJumpVisible(ThreadScroll.showsJump(atBottom: at, distance: new.distance))
        if ThreadScroll.shouldFollow(atBottom: at, old: old, new: new) { followBottom(proxy) }
    }

    /// Brings the bottom on screen, without animation (an animation shakes a growing stream), at most once per
    /// cycle of the run loop however many changes ask for it. Nothing happens if the person scrolled up meanwhile.
    private func followBottom(_ proxy: ScrollViewProxy) {
        guard scroll.alive, !scroll.followScheduled else { return }
        // Older history put above does not move the bottom: one follow is skipped after it.
        if scroll.skipFollow {
            scroll.skipFollow = false
            return
        }
        scroll.followScheduled = true
        DispatchQueue.main.async { [scroll] in
            scroll.followScheduled = false
            guard scroll.alive, atBottom else { return }
            proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom)
        }
    }

    /// The person goes to the newest message (the send, the "down" button): the thread follows the bottom again.
    private func goToBottom(_ proxy: ScrollViewProxy) {
        setAtBottom(true)
        setJumpVisible(false)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom)
        }
    }

    /// The "down" button, when it shows. Kept apart from the scroll chain so the type checker keeps up.
    @ViewBuilder
    private func jumpOverlay(_ proxy: ScrollViewProxy) -> some View {
        if jumpVisible {
            jumpButton { goToBottom(proxy) }
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
        var target = ThreadScroll.restoreTarget(router.threadPlaces[agent.id])
        if case .row = target {
            // The history may not be loaded yet: the row is looked for again once the first items are there.
            if thread.items.isEmpty {
                scroll.restorePending = true
                return
            }
            // The row is looked for among all loaded rows; one older than the window widens the window to it.
            if case .row(let id) = target, !shownRowIDs.contains(id) {
                if let start = startRevealing(row: id) {
                    windowStartID = thread.items[start].id
                    scroll.restorePending = false
                    setAtBottom(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        guard scroll.alive else { return }
                        proxy.scrollTo(id, anchor: .top)
                    }
                    return
                }
            }
            target = ThreadScroll.resolved(target, rowIDs: shownRowIDs)
        }
        scroll.restorePending = false
        switch target {
        case .bottom:
            setAtBottom(true)
            proxy.scrollTo(ThreadScroll.bottomID, anchor: .bottom)
        case .row(let id):
            setAtBottom(false)
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// The composer text of this agent, kept by the Router (see `Router.drafts`).
    private var draft: Binding<String> {
        Binding(get: { router.drafts[agent.id] ?? "" }, set: { router.drafts[agent.id] = $0 })
    }

    var body: some View {
        chatColumn
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

    private var chatColumn: some View {
        VStack(spacing: 0) {
            ThreadHeader(
                agent: agent,
                server: server,
                status: thread.status,
                turnRunning: thread.turnRunning,
                changes: server.info?.supports("changes") == true ? changes : nil,
                showsChanges: server.info?.supports("changes") == true,
                showsTerminal: server.supports("terminals"),
                models: server.runtimeModels,
                onInspect: { showDetails() },
                isLead: server.leadAgentID == agent.id,
                onChanges: { router.showInWorkbench(.changes, agentID: agent.id) },
                onTerminal: { showAgentTerminal() },
                onTogglePanel: { router.toggleWorkbench() },
                showsBrowserChip: WorkbenchRules.showsBrowserChip(
                    state: router.workbenchState(for: agent.id), runningTools: runningToolNames),
                showsBrowserButton: server.supports("browser"),
                onShowBrowser: { router.showInWorkbench(.browser, agentID: agent.id) })

            ScrollViewReader { proxy in
                rows(proxy)
                    // Follow a new item only while the bottom is on screen: prepending older history, or reading
                    // further up, must not jump to the bottom. (Growth of the last item, a stream or an opened
                    // card, is followed from the scroll geometry.)
                    .onChange(of: thread.items.last?.id) { _, _ in
                        guard atBottom else { return }
                        followBottom(proxy)
                    }
                    .onChange(of: thread.items.count, initial: true) { old, new in
                        pinWindow()
                        slideWindow()
                        if !atBottom {
                            unseen += ThreadScroll.unseenAdded(previousCount: old, currentCount: new)
                        }
                    }
                    .onChange(of: bottomRequest) { _, _ in goToBottom(proxy) }
                    .overlay(alignment: .bottomTrailing) {
                        jumpOverlay(proxy)
                    }
                    .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: jumpVisible)
                    .onAppear {
                        scroll.alive = true
                        restore(proxy)
                    }
                    .onChange(of: thread.items.isEmpty) { _, isEmpty in
                        guard !isEmpty, scroll.restorePending else { return }
                        DispatchQueue.main.async {
                            guard scroll.alive, scroll.restorePending else { return }
                            restore(proxy)
                        }
                    }
                    // Rows put above the one on top (older history drawn): the row stays where it was.
                    .onChange(of: shownItems.first?.id) { _, _ in
                        guard let id = scroll.anchorRow else { return }
                        scroll.anchorRow = nil
                        DispatchQueue.main.async {
                            guard scroll.alive else { return }
                            proxy.scrollTo(id, anchor: .top)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                scroll.skipFollow = false
                                // Still at the top after the rows were drawn: once more, not in a loop (an empty
                                // answer never gets here, and the retry is re-armed only after the top was left).
                                if scroll.alive, scroll.nearTop, !scroll.topRetried {
                                    scroll.topRetried = true
                                    topReached()
                                }
                            }
                        }
                    }
                    .onChange(of: scrollRequest) { _, request in
                        guard let request else { return }
                        withAnimation(.easeOut(duration: BanditoMotion.base)) {
                            proxy.scrollTo(request.id, anchor: .center)
                        }
                    }
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
                reply: replyDrafts.target(for: agent.id),
                onCancelReply: { replyDrafts.set(nil, for: agent.id) },
                waitingForm: server.supports("forms") ? thread.pendingForms.last : nil,
                onGoToForm: { scrollTo(id: "form-\($0)") },
                onSend: send,
                onStop: stop,
                onNewChapter: startNewChapter)
                .frame(maxWidth: 780)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.Bandito.bg)
        .task(id: agent.id) {
            await loadHistory()
            // A thread shorter than the screen sits at its top: its older history is read now, not when scrolled to.
            if scroll.nearTop, scroll.contentHeight <= scroll.containerHeight { topReached() }
            await loadChanges()
        }
        .onDisappear {
            jumpTask?.cancel()
            highlightTask?.cancel()
            scroll.alive = false
            let top = ThreadScroll.topRow(spans: scroll.rowSpans, offset: scroll.offset, valid: Set(shownRowIDs))
            router.threadPlaces[agent.id] = ThreadScroll.place(atBottom: atBottom, topRowID: top)
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
        keepTopRow()
        let firstBefore = thread.items.first?.id
        Task {
            defer { loadingOlder = false }
            do { try await server.loadOlder(agent.id) } catch { actionError = UserFacingError.message(for: error) }
            // What was read is drawn, with the row that was on top kept in place.
            if let first = thread.items.first?.id, first != firstBefore, scroll.anchorRow != nil {
                windowStartID = first
            } else {
                scroll.anchorRow = nil
                scroll.skipFollow = false
            }
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

    /// Starts the next chapter now; a running turn finishes first. Failures show in the banner above the composer.
    private func startNewChapter() {
        Task {
            do { try await server.startNewChapter(agent.id) } catch { actionError = UserFacingError.message(for: error) }
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
        let reply = replyDrafts.take(for: id)
        sendError = nil
        // As in any messenger: the person's own message, and the answer to it, are looked at.
        bottomRequest += 1
        Task {
            do {
                try await server.send(text, to: id, replyTo: reply?.seq, attachments: files)
                AttachmentTrays.shared.removeSent(files, agentID: id)
            } catch {
                sendError = UserFacingError.message(for: error)
                router.restoreDraft(text, for: id)
                replyDrafts.restore(reply, for: id)
            }
        }
    }

    // MARK: Messages: replies, reactions, forms

    /// The agent's colour, for the bar of a quote.
    private var accent: Color {
        AvatarResolver.resolve(
            name: agent.name, color: agent.avatar.flatMap { AvatarColor(rawValue: $0.color) }, face: .auto
        ).color.color
    }

    /// What the rows need to offer reactions, replies and forms (see `ThreadChat`).
    private var chat: ThreadChat {
        let current = thread
        let agentID = agent.id
        return ThreadChat(
            reactionsOn: server.supports("reactions"),
            repliesOn: server.supports("attachments"),
            formsOn: server.supports("forms"),
            agentName: agent.name,
            accent: accent,
            reactions: current.reactions,
            replies: current.replies,
            attachments: current.attachments,
            highlightedID: highlightedID,
            original: { seq in Self.original(seq, in: current.items) },
            onReply: { target in
                replyDrafts.set(target, for: agentID)
                router.requestComposerFocus(agentID: agentID)
            },
            onReact: { seq, emoji in react(seq, emoji) },
            onJump: { seq in jump(toMessage: seq) },
            onAnswerForm: { row, action, values, comment in
                try await server.answerForm(row.formId, in: agentID, action: action, values: values, comment: comment)
            })
    }

    /// A message of the loaded history by its `seq`, as something to reply to.
    static func original(_ seq: Int64, in items: [ThreadItem]) -> ReplyTarget? {
        let id = ThreadItem.messageID(seq: seq)
        for item in items where item.id == id {
            switch item {
            case .user(_, let text, _, _, _, _): return ReplyTarget(seq: seq, fromUser: true, text: text)
            case .assistant(_, let text, _): return ReplyTarget(seq: seq, fromUser: false, text: text)
            default: return nil
            }
        }
        return nil
    }

    private func react(_ seq: Int64, _ emoji: String?) {
        let agentID = agent.id
        Task {
            do { try await server.react(emoji, toMessage: seq, of: agentID) } catch {
                actionError = UserFacingError.message(for: error)
            }
        }
    }

    /// Brings a row to the middle of the thread.
    private func scrollTo(id: String) {
        scrollRequest = ScrollRequest(id: id, token: (scrollRequest?.token ?? 0) + 1)
    }

    /// Goes to a message a reply quotes, reading older history first when it is not loaded yet, and lets it flash.
    private func jump(toMessage seq: Int64) {
        jumpTask?.cancel()
        let id = ThreadItem.messageID(seq: seq)
        let agentID = agent.id
        jumpTask = Task { @MainActor in
            var pages = 0
            while !thread.items.contains(where: { $0.id == id }), server.hasMoreHistory[agentID] == true, pages < 12 {
                if Task.isCancelled { return }
                do { try await server.loadOlder(agentID) } catch {
                    actionError = UserFacingError.message(for: error)
                    return
                }
                pages += 1
            }
            guard !Task.isCancelled, let index = thread.items.firstIndex(where: { $0.id == id }) else { return }
            let ids = thread.items.map(\.id)
            if index < ThreadScroll.windowStart(ids: ids, startID: windowStartID) {
                // The message is older than the rows drawn: draw from just above it, then go to it.
                windowStartID = ids[max(0, index - 10)]
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
            }
            scrollTo(id: id)
            highlightedID = id
            highlightTask?.cancel()
            highlightTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled, highlightedID == id { highlightedID = nil }
            }
        }
    }
}

/// A row to scroll to. The token makes a second request for the same row a new value.
private struct ScrollRequest: Equatable {
    var id: String
    var token: Int
}

/// The scroll state of one thread view that must not redraw it: where the rows are, the offset, and the flags of
/// planned work. A reference, so that a scroll changes it without a redraw.
@MainActor
final class ThreadScrollMemory {
    var rowSpans: [String: ThreadRowSpan] = [:]
    var offset = 0.0
    var contentHeight = 0.0
    var containerHeight = 0.0
    /// The metrics last reported (built from the geometry above where the system does not measure the scroll).
    var metrics: ThreadScrollMetrics?
    var nearTop = false
    /// The row to keep on top when rows are put above it.
    var anchorRow: String?
    /// The top was asked for again once after rows were drawn; cleared when the top is left.
    var topRetried = false
    var followScheduled = false
    /// The view is on screen: a planned scroll does nothing after it is gone.
    var alive = false
    /// A restore to a row waits for the history to load.
    var restorePending = false
    var skipFollow = false
}

/// Reports the scroll geometry of the thread (macOS 15 and later): the distance to the bottom, the height of the
/// screen, and the offset and content height the rules read. A change of the whole is reported once; systems without
/// the geometry keep the bottom marker's visibility instead (see `ThreadView`).
private struct ThreadGeometryGate: ViewModifier {
    var onChange: (ThreadScrollMetrics?, ThreadScrollMetrics) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content.onScrollGeometryChange(for: ThreadScrollMetrics.self) { geometry in
                ThreadScrollMetrics(
                    offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                    height: geometry.containerSize.height)
            } action: { old, new in
                onChange(old, new)
            }
        } else {
            content
        }
    }
}

/// The rows of a thread. Separate from the scroll view so it can be rendered on its own (snapshots, previews).
struct ThreadItemsView: View {
    var items: [ThreadItem]
    var server: ServerModel
    var agentID = ""
    var folder: String?
    var onError: (UserFacingMessage) -> Void = { _ in }
    var agentName = ""
    var primaryRuntime = ""
    var chat = ThreadChat()
    /// Shows the typing indicator after the last row while a turn runs.
    var typing = false
    /// Where a row is in the content (its id, top and bottom edge): for the memory of the place.
    var onRowSpan: (String, ThreadRowSpan) -> Void = { _, _ in }
    /// The content's offset in the scroll view and its height.
    var onContent: (Double, Double) -> Void = { _, _ in }

    var body: some View {
        let rows = ThreadRows.build(items)
        var rowChat = chat
        rowChat.lastAgentID = items.last(where: { item in
            if case .assistant = item { return true }
            return false
        })?.id
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                ThreadRowView(
                    row: row, agentName: agentName, primaryRuntime: primaryRuntime, server: server, chat: rowChat,
                    agentID: agentID, folder: folder, onError: onError)
                    .banditoRise()
                    .onGeometryChange(for: ThreadRowSpan.self) { proxy in
                        let frame = proxy.frame(in: .named(ThreadScroll.contentSpace))
                        return ThreadRowSpan(minY: Double(frame.minY).rounded(), maxY: Double(frame.maxY).rounded())
                    } action: { span in
                        onRowSpan(row.id, span)
                    }
            }
            if typing {
                TypingIndicator(activity: AgentActivity.current(in: items), since: AgentActivity.turnStart(in: items))
            }
            Color.clear.frame(height: 1).id(ThreadScroll.bottomID)
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: ThreadScroll.contentSpace)
        .onGeometryChange(for: ThreadRowSpan.self) { proxy in
            let frame = proxy.frame(in: .named(ThreadScroll.scrollSpace))
            // minY..maxY is the content's place in the scroll view: -minY is the offset, the length the height.
            return ThreadRowSpan(minY: Double(-frame.minY).rounded(), maxY: Double(frame.height).rounded())
        } action: { span in
            onContent(span.minY, span.maxY)
        }
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
