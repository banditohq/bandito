import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The thread of one agent: header, the rows, banners and the composer.
///
/// One view for every agent: a switch gives it another `agent`, and the header, the composer and the list (with its
/// cells) are kept and given the new agent, not built again (a new view per agent was 50–100 ms at each switch). What
/// belongs to one agent's chat (the scroll, the flags, the banners) is a `ThreadSession`, made fresh for each agent.
struct ThreadView: View {
    var server: ServerModel
    var agent: Agent
    /// Which replies are read aloud (a reference type: changes do not redraw the thread).
    @State private var readAloud = ReadAloudTracker()
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kept built under another mode (`KeptMode`): the list's views are hidden (no pointer shapes, no hover).
    @Environment(\.modeHidden) private var hidden
    /// The window is inactive when the person works elsewhere: the chat is not looked at then (its replies stay unread).
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// Files are dragged over the chat.
    @State private var dropTargeted = false
    /// Counts the requests to scroll to the bottom (the send, the "down" button); the scroll chain answers each one.
    @State private var bottomRequest = 0
    /// The AppKit list of the rows, and how the thread moves it (see `ThreadList`).
    @State private var list = ThreadListController()
    /// The chat state of the agent on screen (see `ThreadSession`).
    @State private var sessions = ThreadSessions()

    /// The session of this view's agent. A closure that outlived a switch (an answer that came late) holds the agent
    /// it was made for: it gets a session of its own that nothing shows, so it never writes into another agent's chat.
    private var session: ThreadSession { sessions.lookup(agent.id) }
    private var scroll: ThreadScrollMemory { session.scroll }
    private var arrival: ThreadArrival { session.arrival }
    private var sendError: UserFacingMessage? {
        get { session.sendError }
        nonmutating set { session.sendError = newValue }
    }
    private var actionError: UserFacingMessage? {
        get { session.actionError }
        nonmutating set { session.actionError = newValue }
    }
    private var connectSheet: AgentConnectRules.SheetItem? {
        get { session.connectSheet }
        nonmutating set { session.connectSheet = newValue }
    }
    private var loadingOlder: Bool {
        get { session.loadingOlder }
        nonmutating set { session.loadingOlder = newValue }
    }
    private var changes: ChangesDiff? {
        get { session.changes }
        nonmutating set { session.changes = newValue }
    }
    private var atBottom: Bool {
        get { session.atBottom }
        nonmutating set { session.atBottom = newValue }
    }
    private var jumpVisible: Bool {
        get { session.jumpVisible }
        nonmutating set { session.jumpVisible = newValue }
    }
    private var unseen: Int {
        get { session.unseen }
        nonmutating set { session.unseen = newValue }
    }
    private var scrollRequest: ScrollRequest? {
        get { session.scrollRequest }
        nonmutating set { session.scrollRequest = newValue }
    }
    private var highlightedID: String? {
        get { session.highlightedID }
        nonmutating set { session.highlightedID = newValue }
    }
    private var jumpTask: Task<Void, Never>? {
        get { session.jumpTask }
        nonmutating set { session.jumpTask = newValue }
    }
    private var highlightTask: Task<Void, Never>? {
        get { session.highlightTask }
        nonmutating set { session.highlightTask = newValue }
    }

    /// Hooks the list's reports into the rules of the thread's scroll.
    private func attachList() {
        list.onMetrics = { new in
            let old = scroll.metrics
            scroll.metrics = new
            scroll.contentHeight = Double(new.contentHeight)
            scroll.containerHeight = Double(new.height)
            scroll.nearTop = ThreadScroll.nearTop(offset: Double(new.offset))
            if !scroll.nearTop { scroll.topRetried = false }
            // Where the chat is left, kept as it moves: a switch keeps it for the agent left (see `agentChanged`).
            if old?.offset != new.offset { scroll.topRow = list.topRowID() }
            scrollGeometryChanged(old, new)
        }
        list.onNearTop = { DispatchQueue.main.async { topReached() } }
    }
    private var replyDrafts: ReplyDrafts { ReplyDrafts.shared }

    private var thread: AgentThread { server.thread(for: agent.id) }
    /// What the frame of the chat (header, composer, banners) shows of the thread. Its body reads this, not `thread`:
    /// a streamed token changes the thread, not the summary, and must not build the header and the composer again.
    /// Only the rows (`ThreadRowsScope`) and the watcher (`ThreadWatch`) read the thread itself.
    private var summary: AgentThreadState { server.threadSummary(for: agent.id) }

    /// The tools the agent is running now, by name (a tool row without a result yet).
    private var runningToolNames: [String] {
        WorkbenchRules.runningToolNames(summary.unfinishedTools, now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// The agent's details in the workbench, on their details tab (the capsule and the schedules button).
    private func showDetails() {
        router.inspectorTab = .details
        router.showInWorkbench(.details, agentID: agent.id)
    }

    /// The agent's terminal in the workbench: the one in its folder, or a new one there.
    private func showAgentTerminal() {
        #if os(macOS)
        WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
        #endif
    }

    /// The rows in the AppKit list (`ThreadList`): a scroll moves layers, and a row is made only when it comes into
    /// view. Every loaded row is in the list; the lines are kept between updates (`ThreadListMemo`), so a token makes
    /// the streamed row's line only.
    private var rowList: some View {
        let items = thread.items
        let rows = scroll.rows.rows(of: items)
        var rowChat = chat
        rowChat.lastAgentID = ThreadListLine.lastAgentID(in: items)
        let signature = ThreadListMemo.Signature(
            chat: rowChat, agentName: agent.name, runtime: agent.runtime.rawValue, agentID: agent.id, folder: agent.cwd,
            baseline: arrival.baseline)
        let typing: ThreadListLine? =
            thread.turnRunning && !isStreaming
            ? .typing(AgentActivity.current(in: items), since: thread.turnStartedAt) : nil
        let version = scroll.listMemo.update(rows: rows, memo: scroll.rows, signature: signature, typing: typing) { row in
            .row(
                ThreadRowKey(
                    row: row, agentName: agent.name, primaryRuntime: agent.runtime.rawValue, agentID: agent.id,
                    folder: agent.cwd, chat: rowChat),
                live: arrival.isLive(seq: ThreadArrival.seq(of: row)))
        }
        return ThreadList(
            lines: scroll.listMemo.box, version: version,
            context: ThreadListContext(
                server: server,
                openLink: { [router, agent, server] url in
                    ChatLinkText.open(url, agentID: agent.id, folder: agent.cwd, server: server, router: router)
                },
                agentID: agent.id, chat: rowChat, onError: { actionError = $0 }),
            controller: list, hidden: hidden)
    }

    /// The top of the thread came near: older history is read.
    private func topReached() {
        guard scroll.alive, !thread.items.isEmpty, server.hasMoreHistory[agent.id] == true else { return }
        loadEarlier()
    }

    /// Notes the row on top before older rows are put above it: the list keeps it in place, and the follow of the bottom
    /// is skipped once for the growth.
    private func keepTopRow() {
        scroll.anchorRow = list.topRowID()
        if scroll.anchorRow != nil { scroll.skipFollow = true }
    }

    /// Writes the flags only when they really change: a scroll reports many times, the flags rarely change.
    private func setAtBottom(_ value: Bool) {
        if atBottom != value {
            atBottom = value
            if value { lookedAt() }
        }
        if value && unseen != 0 { unseen = 0 }
    }

    /// The chat is looked at now (`UnreadRules.isLookedAt`): its replies are read, for the team list's unread counts.
    /// Called where the chat's state changes; the mark moves only when there is a new reply to read.
    private func lookedAt() {
        guard UnreadRules.isLookedAt(
            onScreen: sessions.onScreen, hidden: hidden, windowActive: controlActiveState != .inactive,
            atBottom: atBottom, sendPinned: scroll.sendPinned)
        else { return }
        summary.markRead()
    }

    private func setJumpVisible(_ value: Bool) {
        if jumpVisible != value { jumpVisible = value }
    }

    /// The list moved or changed size: the bottom, the "down" button and the follow of the bottom all follow from the
    /// measured distance.
    private func scrollGeometryChanged(_ old: ThreadScrollMetrics?, _ new: ThreadScrollMetrics) {
        if let old, old.offset != new.offset { ThreadScrollActivity.noteMove() }
        // After a send the thread follows the bottom until the person scrolls up themselves.
        // A layout settling (rows rising in, the composer changing height) does not end it; the person's own scroll
        // up does (see `ThreadFollowRules`).
        if scroll.sendPinned, let old {
            scroll.sendPinned = ThreadFollowRules.holds(
                pinned: true, leavesBottom: ThreadScroll.leavesBottom(old: old, new: new), distance: new.distance,
                secondsSinceSend: ProcessInfo.processInfo.systemUptime - scroll.sendPinnedAt)
        }
        // While the follow holds the thread is at the bottom by definition: the "down" button stays away.
        let flags =
            scroll.sendPinned
            ? (atBottom: true, jump: false)
            : ThreadScroll.flags(was: atBottom, old: old, new: new, pinned: false)
        setAtBottom(flags.atBottom)
        setJumpVisible(flags.jump)
        if ThreadScroll.shouldFollow(atBottom: flags.atBottom, old: old, new: new) { followBottom() }
    }

    /// Brings the bottom on screen, without animation (an animation shakes a growing stream), at most once per
    /// cycle of the run loop however many changes ask for it. Nothing happens if the person scrolled up meanwhile.
    private func followBottom() {
        guard scroll.alive, !scroll.followScheduled else { return }
        // Older history put above does not move the bottom: one follow is skipped after it.
        if scroll.skipFollow {
            scroll.skipFollow = false
            return
        }
        scroll.followScheduled = true
        DispatchQueue.main.async { [scroll, list] in
            scroll.followScheduled = false
            guard scroll.alive, atBottom else { return }
            list.scrollToBottom(slide: nil)
        }
    }

    /// The person goes to the newest message (the send, the "down" button): the thread follows the bottom again.
    private func goToBottom() {
        scroll.skipFollow = false
        setAtBottom(true)
        setJumpVisible(false)
        scrollToBottomSmoothly()
    }

    /// Whether motion is dropped (Reduce Motion, or "Off" in Settings).
    private var motionReduced: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
    }

    /// Slides the thread to its bottom: one soft move, or a plain jump while motion is reduced. The bottom is the end
    /// of the last row, so a message taller than the screen shows its end.
    private func scrollToBottomSmoothly() {
        list.scrollToBottom(slide: ThreadFollowRules.scrollAnimation(reduced: motionReduced))
    }

    /// The person sent a message: the thread follows the bottom until they scroll up themselves, and the capsule and
    /// its count stay out of it.
    private func beginSendFollow() {
        scroll.sendPinned = true
        scroll.sendPinnedAt = ProcessInfo.processInfo.systemUptime
        unseen = 0
        bottomRequest += 1
    }

    /// An item arrived while the follow after a send is on (the person's message as the daemon echoes it, then the
    /// answer): the thread slides to its bottom once its row is in the list. At most one planned at a time; the growth
    /// that follows (rows rising in, a stream) is followed from the scroll metrics.
    private func followArrival() {
        guard scroll.sendPinned else { return }
        setAtBottom(true)
        setJumpVisible(false)
        guard scroll.alive, !scroll.arrivalScrollScheduled else { return }
        scroll.arrivalScrollScheduled = true
        scroll.skipFollow = false
        // After the update that puts the new row in the list, so the bottom is where the row ends.
        DispatchQueue.main.async { [scroll] in
            scroll.arrivalScrollScheduled = false
            guard scroll.alive, scroll.sendPinned else { return }
            scrollToBottomSmoothly()
        }
    }

    /// Shows the thread where it was left: the row that was on top, or the newest message.
    private func restore() {
        var target = ThreadScroll.restoreTarget(router.threadPlaces[agent.id])
        if case .row = target {
            // The history may not be loaded yet: the row is looked for again once the first items are there.
            if thread.items.isEmpty {
                scroll.restorePending = true
                return
            }
            target = ThreadScroll.resolved(target, rowIDs: scroll.rows.rows(of: thread.items).map(\.id))
        }
        scroll.restorePending = false
        switch target {
        case .bottom:
            setAtBottom(true)
            list.scrollToBottom(slide: nil)
        case .row(let id):
            setAtBottom(false)
            list.scroll(to: id, centered: false, slide: nil)
        }
    }

    /// A suggestion of the empty thread: its text goes into the composer after what is there, unsent, and the field takes
    /// the keyboard. The same path as a template's starter (`Router.appendDraft`).
    private func pickSuggestion(_ text: String) {
        router.appendDraft(text, for: agent.id)
        router.requestComposerFocus(agentID: agent.id)
    }

    var body: some View {
        let _ = PerfCounters.hit("ThreadView")
        // The body is where a switch begins: the agent shown now gets its session before anything reads it.
        let _ = sessions.enter(agent.id)
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

    // Split in two statements: the type checker took 285 ms on one chain this long.
    private var chatColumnBase: some View {
        VStack(spacing: 0) {
            ThreadHeader(
                agent: agent,
                server: server,
                status: summary.loadedStatus ?? .idle,
                turnRunning: summary.turnRunning,
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
            if let movedTo = agent.migratedTo {
                MigratedAgentStrip(agent: agent, source: server, movedTo: movedTo)
            }

            ThreadRowsScope { rowList }
                .background {
                    ThreadWatch(
                        server: server, agentID: agent.id,
                        onLastItem: {
                            lastItemChanged()
                            readNewReply()
                        },
                        onCount: { old, new in countChanged(old, new) },
                        onFilled: {
                            guard scroll.restorePending else { return }
                            DispatchQueue.main.async {
                                guard scroll.alive, scroll.restorePending else { return }
                                restore()
                            }
                        },
                        onFirstChanged: { firstChanged() })
                }
                .onChange(of: bottomRequest) { _, _ in goToBottom() }
                .overlay(alignment: .bottom) {
                    ThreadJumpOverlay(visible: jumpVisible, unseen: unseen) { goToBottom() }
                }
                .onAppear {
                    sessions.onScreen = true
                    scroll.alive = true
                    attachList()
                    restore()
                    lookedAt()
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    list.scroll(
                        to: request.id, centered: true,
                        slide: motionReduced ? nil : ThreadSlide(duration: BanditoMotion.base, curve: ThreadSlide.easeOut))
                }
            .overlay {
                // The first screen of a thread with no message. It waits for the history: `hasMoreHistory` is set once the
                // first page is read, so a thread that has messages on the server never flashes it.
                if summary.isEmpty, server.hasMoreHistory[agent.id] != nil {
                    ThreadEmptyState(agent: agent, server: server, onPick: pickSuggestion)
                        .id(agent.id)
                }
            }
            if summary.loadedStatus == .error, let detail = summary.statusDetail {
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
            QuickRepliesHost(server: server, agentID: agent.id, onReply: sendQuickReply, onOpen: openQuickLink)
                .id(agent.id)
            Composer(
                agentName: agent.name,
                running: summary.turnRunning,
                contextFraction: ContextUsage.fraction(tokens: agent.contextTokens, budget: agent.contextBudget),
                agent: agent,
                server: server,
                reply: replyDrafts.target(for: agent.id),
                onCancelReply: { replyDrafts.set(nil, for: agent.id) },
                waitingForm: server.supports("forms") ? summary.pendingForms.last : nil,
                onGoToForm: { scrollTo(id: "form-\($0)") },
                waitingConnect: connectWait,
                onGoToConnect: { scrollTo(id: "connect-\($0)") },
                replyFormId: ComposerSendMode.formToAnswer(
                    in: summary.pendingForms, supportsReply: server.supports("form_reply")),
                onReplyToForm: replyToForm,
                onSend: send,
                onStop: stop,
                onNewChapter: startNewChapter,
                showsHints: summary.isEmpty)
                .frame(maxWidth: 780)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.Bandito.bg)
    }

    private var chatColumn: some View {
        chatColumnBase
        .task(id: agent.id) {
            await loadHistory()
            // What is read now is the old history: a message that comes after it is new (see `ThreadArrival`).
            arrival.settle(thread.items)
            lookedAt()
            // A thread shorter than the screen sits at its top: its older history is read now, not when scrolled to.
            if scroll.nearTop, scroll.contentHeight <= scroll.containerHeight { topReached() }
            await loadChanges()
        }
        .onDisappear {
            sessions.onScreen = false
            session.leave()
            // The list's reports held this view: they are let go with it (made again on appearing).
            list.onMetrics = nil
            list.onNearTop = nil
            let top = list.topRowID()
            router.threadPlaces[agent.id] = ThreadScroll.place(atBottom: atBottom, topRowID: top)
        }
        // The header names the model from the server's list, so the list is asked once per server, not on opening
        // the inspector. The daemon caches the answer, so a repeat of this request is cheap.
        .task(id: server.id) {
            _ = try? await server.refreshRuntimeModels()
        }
        // A card that asks for a service names it from the catalog: read once there is one (it is kept per server).
        .task(id: connectCardCount) {
            if connectCardCount > 0, server.supports("agent_connect") { await MentionServices.shared.ensure(server) }
        }
        .banditoSheet(item: Binding(get: { connectSheet }, set: { connectSheet = $0 }), dismissOnOutsideClick: false) {
            item in
            IntegrationEditor(
                server: server, target: item.target,
                existingNames: MentionServices.shared.snapshot(for: server)?.integrations.map(\.name) ?? [],
                onChecked: { _, _ in }, onSaved: { await MentionServices.shared.ensure(server, force: true) },
                connectRequestId: item.requestId)
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
        .onChange(of: summary.turnRunning) { wasRunning, isRunning in
            if wasRunning && !isRunning {
                Task { await loadChanges() }
            }
            readNewReply()
        }
        .onChange(of: agent.id) { _, _ in agentChanged() }
        .onChange(of: controlActiveState) { _, _ in lookedAt() }
        .onChange(of: hidden) { _, _ in lookedAt() }
    }

    /// Another agent is shown in this view: the place of the one left is kept, as leaving the chat keeps it, and the new
    /// one is shown where it was left. The list already has the new rows (the body switched the session).
    private func agentChanged() {
        readAloud.reset()
        // The list's reports go to this agent's chat from now on.
        attachList()
        if let left = sessions.takeLeft() {
            router.threadPlaces[left.agentID] = ThreadScroll.place(
                atBottom: left.session.atBottom, topRowID: left.session.scroll.topRow)
        }
        restore()
        lookedAt()
    }

    /// A new last item: the echo of the person's own message (and the answer to it) is looked at; else the bottom is
    /// followed while it is on screen. Prepending older history, or reading further up, must not jump to the bottom.
    /// (Growth of the last item, a stream or an opened card, is followed from the scroll geometry.)
    private func lastItemChanged() {
        // A reply that is finished in place (a stream) changes the last row, not the count: it is looked at here.
        lookedAt()
        if scroll.sendPinned {
            followArrival()
            return
        }
        guard atBottom else { return }
        followBottom()
    }

    private func countChanged(_ old: Int, _ new: Int) {
        if ThreadJumpRules.countsAsUnseen(atBottom: atBottom, sendPinned: scroll.sendPinned) {
            unseen += ThreadScroll.unseenAdded(previousCount: old, currentCount: new)
        } else if scroll.sendPinned, new > old {
            // An item that came in after a send (also one that keeps the last id, as an edit of the same row does
            // not): the follow takes it.
            followArrival()
        }
        lookedAt()
    }

    /// Older rows were put above the one on top (the list keeps it where it was): the follow of the bottom comes back
    /// once they settled, and a thread still at its top reads one more page, once.
    private func firstChanged() {
        guard scroll.anchorRow != nil else { return }
        scroll.anchorRow = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            scroll.skipFollow = false
            // An empty answer never gets here, and the retry is re-armed only after the top was left.
            if scroll.alive, scroll.nearTop, !scroll.topRetried {
                scroll.topRetried = true
                topReached()
            }
        }
    }

    /// Reads a new final reply aloud when the agent has "Read replies aloud" on and Bandito is the active app. A reply
    /// that comes while the app is in the background is passed over, not read later.
    private func readNewReply() {
        guard let reply = readAloud.observe(items: thread.items, turnRunning: thread.turnRunning) else { return }
        guard ReadAloud.isOn(agentID: agent.id), NSApplication.shared.isActive else { return }
        let spoken = SpeechText.plain(reply.text, codeSkipped: L10n.Speech.codeSkipped)
        let voice = SpeechLanguage.voiceTag(for: spoken, appLanguage: SpeechLanguage.appLanguage)
        SpeechOutput.shared.speak(spoken, key: reply.id, voiceTag: voice)
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
            // Nothing was put above: the follow of the bottom is not held back.
            if thread.items.first?.id == firstBefore {
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
        let draftMentions = router.takeMentions(for: id)
        let mentions = MentionDraft.wire(draftMentions, in: text)
        // The files that finished uploading go with the text; a failed send leaves them in the tray for a retry.
        let files = AttachmentTray.readyFiles(AttachmentTrays.shared.files(for: id))
        guard !text.isEmpty || !files.isEmpty else { return }
        let reply = replyDrafts.take(for: id)
        sendError = nil
        // As in any messenger: the person's own message, and the answer to it, are looked at.
        beginSendFollow()
        Task {
            do {
                try await server.send(text, to: id, replyTo: reply?.seq, attachments: files, mentions: mentions)
                AttachmentTrays.shared.removeSent(files, agentID: id)
            } catch {
                scroll.sendPinned = false
                sendError = UserFacingError.message(for: error)
                router.restoreDraft(text, for: id)
                router.restoreMentions(draftMentions, for: id)
                replyDrafts.restore(reply, for: id)
            }
        }
    }

    /// Sends the text of a quick-reply button as the person's message. `false` when it did not go out.
    private func sendQuickReply(_ text: String) async -> Bool {
        sendError = nil
        beginSendFollow()
        do {
            // The text is a button's reply: the daemon marks it so, after checking it is one of the buttons shown.
            try await server.send(text, to: agent.id, viaButton: true)
            return true
        } catch {
            scroll.sendPinned = false
            sendError = UserFacingError.message(for: error)
            return false
        }
    }

    /// Opens the page of a quick-reply link as a link in a message opens.
    private func openQuickLink(_ url: URL) {
        ChatLinkText.open(url, agentID: agent.id, folder: agent.cwd, server: server, router: router)
    }

    /// Answers the form the agent waits on with the typed message. A failure puts the text back in the field.
    private func replyToForm(_ formId: String) {
        let id = agent.id
        let text = router.takeDraft(for: id).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = router.takeMentions(for: id)
        guard !text.isEmpty else { return }
        sendError = nil
        beginSendFollow()
        Task {
            do {
                try await server.answerForm(formId, in: id, action: .reply, message: text)
                Telemetry.count(.formReply)
            } catch {
                scroll.sendPinned = false
                sendError = FormPresentation.message(for: error)
                router.restoreDraft(text, for: id)
            }
        }
    }

    // MARK: Messages: replies, reactions, forms

    /// How many connect cards the thread holds; a change of it reads the catalog.
    private var connectCardCount: Int { summary.connectCardCount }

    /// The service an agent waits on the person to connect, for the hint above the field.
    private var connectWait: ConnectWait? {
        guard server.supports("agent_connect") else { return nil }
        return AgentConnectRules.waiting(
            in: summary.pendingConnects, catalog: MentionServices.shared.snapshot(for: server)?.catalog ?? [])
    }

    /// Pressing Connect on a card: the same connection as the Marketplace (see `AgentConnectRules`). The daemon sees
    /// the service come up by itself and answers the agent.
    private func connectService(_ row: ConnectRow) {
        Task {
            await MentionServices.shared.ensure(server, force: true)
            let snapshot = MentionServices.shared.snapshot(for: server)
            guard let entry = snapshot?.catalog.first(where: { $0.id == row.service }) else {
                actionError = UserFacingMessage(text: L10n.AgentConnect.unknown(service: row.service))
                return
            }
            let existing = AgentConnectRules.existing(for: entry, in: snapshot?.integrations ?? [])
            switch AgentConnectRules.start(
                entry: entry, existing: existing, supportsOAuth: server.supports("integrations_oauth"),
                supportsDevice: server.supports("integrations_device"))
            {
            case .signIn(let target):
                await app.oauth.begin(server: server, target: target, name: entry.name, connectRequestId: row.requestId)
            case .deviceSignIn(let target):
                await app.device.begin(server: server, target: target, name: entry.name, connectRequestId: row.requestId)
            case .sheet(let target):
                connectSheet = AgentConnectRules.SheetItem(target: target, requestId: row.requestId)
            case .needsUpdate(let device):
                actionError = UserFacingMessage(
                    text: device
                        ? L10n.Integrations.Device.needsUpdate(name: entry.name)
                        : L10n.Integrations.Oauth.needsUpdate(name: entry.name))
            }
        }
    }

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
            connectOn: server.supports("agent_connect"),
            agentName: agent.name,
            accent: accent,
            reactions: current.reactions,
            replies: current.replies,
            attachments: current.attachments,
            mentions: current.mentions,
            viaButton: current.viaButton,
            waiting: current.waitingSeqs,
            undelivered: current.undeliveredSeqs,
            onResend: { seq in resend(seq) },
            highlightedID: highlightedID,
            original: Self.originals(current),
            onReply: { target in
                replyDrafts.set(target, for: agentID)
                router.requestComposerFocus(agentID: agentID)
            },
            onReact: { seq, emoji in react(seq, emoji) },
            onJump: { seq in jump(toMessage: seq) },
            onAnswerForm: { row, action, values, comment in
                try await server.answerForm(row.formId, in: agentID, action: action, values: values, comment: comment)
            },
            onConnectService: { row in connectService(row) },
            onDeclineConnect: { row in try await server.declineConnect(row.requestId) })
    }

    /// The messages that replies quote, found in one pass over the items (only when the thread has replies): a lookup
    /// per row used to walk every item, for every row with a quote, at every token of a stream.
    static func originals(_ thread: AgentThread) -> (Int64) -> ReplyTarget? {
        let wanted = Set(thread.replies.values)
        guard !wanted.isEmpty else { return { _ in nil } }
        var found: [Int64: ReplyTarget] = [:]
        for item in thread.items {
            guard let seq = item.messageSeq, wanted.contains(seq) else { continue }
            found[seq] = original(seq, in: [item])
        }
        return { found[$0] }
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

    /// Sends a message the daemon gave up on once more (see `ServerModel.resendUndelivered`).
    private func resend(_ seq: Int64) {
        let agentID = agent.id
        Task {
            do {
                let dropped = try await server.resendUndelivered(seq, of: agentID)
                if !dropped.isEmpty {
                    let names = dropped.map(\.label).joined(separator: ", ")
                    actionError = UserFacingMessage(text: L10n.Mention.resendDropped(names: names))
                }
            } catch {
                actionError = UserFacingError.message(for: error)
            }
        }
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
            guard !Task.isCancelled, thread.items.contains(where: { $0.id == id }) else { return }
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
fileprivate struct ScrollRequest: Equatable {
    var id: String
    var token: Int
}

/// What one agent's chat holds while it is on screen: the scroll, the flags of the bottom and the "down" button, the
/// banners, the row to bring on screen. Made fresh for each agent the view shows.
@MainActor
@Observable
final class ThreadSession {
    var sendError: UserFacingMessage?
    /// Failures of interrupt, approval and history loading.
    var actionError: UserFacingMessage?
    /// The sheet of keys a connect card opened (see `ThreadView.connectService`).
    var connectSheet: AgentConnectRules.SheetItem?
    var loadingOlder = false
    /// Files changed since the last checkpoint; `nil` until loaded or when the server lacks `changes`.
    var changes: ChangesDiff?
    /// Whether the newest message is on screen.
    var atBottom = true
    /// The "down" button shows (see `ThreadScroll.showsJump`), and how many messages came in while the person is above.
    var jumpVisible = false
    var unseen = 0
    /// A row to bring on screen (a quoted message, a form), and the row that flashes after it.
    fileprivate var scrollRequest: ScrollRequest?
    var highlightedID: String?
    /// The scroll position, kept outside the observed state: a scroll must not redraw the header and the composer.
    @ObservationIgnored let scroll = ThreadScrollMemory()
    /// Which messages arrived after the chat opened (see `ThreadArrival`).
    @ObservationIgnored let arrival = ThreadArrival()
    @ObservationIgnored var jumpTask: Task<Void, Never>?
    @ObservationIgnored var highlightTask: Task<Void, Never>?

    /// The chat is gone from the screen: its planned work stops.
    func leave() {
        jumpTask?.cancel()
        highlightTask?.cancel()
        scroll.alive = false
    }
}

/// The session of the agent a `ThreadView` shows, and the one it showed before until its place is kept.
@MainActor
final class ThreadSessions {
    private var agentID: String?
    private var current: ThreadSession?
    private var left: (agentID: String, session: ThreadSession)?
    /// The view is on screen: a new session starts alive.
    var onScreen = false

    /// Makes `id` the agent shown, with a fresh session when it is another one. Called by the body only.
    @discardableResult
    func enter(_ id: String) -> ThreadSession {
        if let current, agentID == id { return current }
        if let current, let agentID {
            current.leave()
            left = (agentID, current)
        }
        let session = ThreadSession()
        session.scroll.alive = onScreen
        current = session
        agentID = id
        return session
    }

    /// The session of `id`: the current one, or for an agent no longer shown one that nothing reads.
    func lookup(_ id: String) -> ThreadSession {
        if let current, agentID == id { return current }
        if agentID == nil { return enter(id) }
        let stray = ThreadSession()
        stray.scroll.alive = false
        return stray
    }

    /// The agent left by the last switch, once.
    func takeLeft() -> (agentID: String, session: ThreadSession)? {
        defer { left = nil }
        return left
    }
}

/// The scroll state of one thread view that must not redraw it: the rows and lines last made, the metrics, and the
/// flags of planned work. A reference, so that a scroll changes it without a redraw.
@MainActor
final class ThreadScrollMemory {
    /// The rows of the thread last made (see `ThreadRowsMemo`).
    let rows = ThreadRowsMemo()
    /// The lines of the list last made, kept for the next update (see `ThreadListMemo`).
    let listMemo = ThreadListMemo()
    var contentHeight = 0.0
    var containerHeight = 0.0
    /// The metrics the list last reported.
    var metrics: ThreadScrollMetrics?
    /// The row on top of what shows, as of the last move.
    var topRow: String?
    var nearTop = false
    /// The row on top when older rows were asked for: set while they are being put above it.
    var anchorRow: String?
    /// The top was asked for again once after rows were drawn; cleared when the top is left.
    var topRetried = false
    var followScheduled = false
    /// The view is on screen: a planned scroll does nothing after it is gone.
    var alive = false
    /// A restore to a row waits for the history to load.
    var restorePending = false
    var skipFollow = false
    /// The person sent a message: the thread follows the bottom until they scroll up themselves.
    var sendPinned = false
    /// When the person sent it (`systemUptime`): the follow is not ended by what happens in its first moments.
    var sendPinnedAt = 0.0
    /// The scroll to the person's own message, once its row is in the list, is planned or done.
    var arrivalScrollScheduled = false
}

/// Watches one agent's thread for the changes the chat answers to: a new last item, a new number of items, the first
/// items of an empty thread, older items put above. The chat itself does not read the thread (see
/// `ThreadView.summary`): a streamed token builds this empty view again, not the chat's header and composer.
private struct ThreadWatch: View {
    let server: ServerModel
    let agentID: String
    var onLastItem: () -> Void
    var onCount: (Int, Int) -> Void
    /// The thread was empty and has items now.
    var onFilled: () -> Void
    /// Another item is the first one (older history was read).
    var onFirstChanged: () -> Void

    var body: some View {
        let items = server.thread(for: agentID).items
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: items.last?.id) { _, _ in onLastItem() }
            .onChange(of: items.count, initial: true) { old, new in onCount(old, new) }
            .onChange(of: items.isEmpty) { _, isEmpty in if !isEmpty { onFilled() } }
            .onChange(of: items.first?.id) { _, _ in onFirstChanged() }
            .accessibilityHidden(true)
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
            Text(text).font(BanditoFont.text(size: 12, weight: 400)).foregroundStyle(Color.Bandito.text).textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
