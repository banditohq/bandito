import BanditoKit
import Foundation
import Observation
import SwiftUI
import UIKit

/// What changed in the list since the screen last drew it.
struct ChatUpdate {
    /// The rows now, in order.
    var rows: [ChatRow]
    /// The height of each row (a row of a card has the height it was measured at).
    var heights: [String: CGFloat]
    /// Rows that were in the list and whose facts changed: their cells are set up again.
    var changed: [String]
    /// Rows that came in above the first row that was already there (older history).
    var prepended: Int
    /// The first update of the screen.
    var initial: Bool
}

extension ChatUpdate {
    /// Two updates that were not applied one by one become one: the rows and heights of the newer, every row that
    /// changed in either, the rows that came in above, and the first-update flag of either. Dropping the older would
    /// lose the cell of a stream that changed in it.
    static func merge(_ older: ChatUpdate, _ newer: ChatUpdate) -> ChatUpdate {
        var seen = Set<String>()
        let changed = (older.changed + newer.changed).filter { seen.insert($0).inserted }
        return ChatUpdate(
            rows: newer.rows, heights: newer.heights, changed: changed, prepended: older.prepended + newer.prepended,
            initial: older.initial || newer.initial)
    }
}

/// The chat of one agent: the thread seen as rows, kept in step with the server. The thread's changes are folded together
/// (a stream changes it at every token), the rows are built and measured off the main thread, and the screen is told what
/// changed. The screen never reads the thread itself.
@MainActor
final class ChatModel {
    let server: ServerModel
    let agentID: String
    let engine: ChatLayoutEngine
    let outbox: ChatOutbox

    private(set) var rows: [ChatRow] = []
    private(set) var heights: [String: CGFloat] = [:]
    private(set) var changes: ChatChangesSummary?
    /// Rows the person opened (a tool group, a scheduled run).
    private(set) var expanded: Set<String> = []
    /// The history is being read (the first time, or after "Try again").
    private(set) var isLoading = true
    /// The history could not be read and nothing else shows: the screen says so and offers "Try again".
    private(set) var loadFailed = false
    private(set) var loadingOlder = false
    /// Called with what changed. Set by the screen.
    var onUpdate: ((ChatUpdate) -> Void)?
    /// Called when the list has nothing to draw yet or no more: the empty state shows.
    var onEmptyChange: ((Bool) -> Void)?
    /// Called when the load state changed (loading, failed, done): the screen shows or takes away what it says about it.
    var onLoadStateChange: (() -> Void)?

    private(set) var metrics: ChatMetrics?
    private var updating = false
    private var dirty = false
    private var started = false
    private var changesTask: Task<Void, Never>?
    private var lastTurnRunning = false
    private var hostedHeights: [String: CGFloat] = [:]
    private let sizer = ChatHostedSizer()
    private var updateCount = 0

    /// The copy of the chat kept on disk (nil: none is kept, as in most tests).
    private let history: ChatHistoryCache?
    /// The saved chat, drawn while the real one is not read.
    private var saved: SavedChat?
    private var cacheTask: Task<Void, Never>?
    /// A reaction the person asked for, drawn before the daemon's event comes back; nil emoji: taken off.
    private var wanted: [Int64: Wanted] = [:]
    private var emptyPages = 0
    /// The most older pages read to find a message when the newest page shows nothing.
    static let emptyPageLimit = 10

    struct Wanted: Equatable {
        var emoji: String?
    }

    /// The saved chat as the builder wants it.
    private struct SavedChat {
        var thread: AgentThread
        var replies: [Int64: Int64]
        var reactions: [Int64: [ChatReactionChip]]
    }

    init(
        server: ServerModel, agentID: String, engine: ChatLayoutEngine = .shared, outbox: ChatOutbox = .shared,
        history: ChatHistoryCache? = .shared
    ) {
        self.server = server
        self.agentID = agentID
        self.engine = engine
        self.outbox = outbox
        self.history = history
    }

    /// The screen shows the saved chat, not the server's: nothing has been read yet.
    var showsSavedHistory: Bool { saved != nil && !summary.loaded }

    var agentName: String { server.agents.first { $0.id == agentID }?.name ?? "" }
    private var primaryRuntime: String { server.agents.first { $0.id == agentID }?.runtime.rawValue ?? "" }
    var summary: AgentThreadState { server.threadSummary(for: agentID) }

    /// The number of updates made so far (tests wait on it).
    var updates: Int { updateCount }

    // MARK: life

    /// Loads the thread when it is not loaded, and starts following it. The saved copy is read at the same time and
    /// drawn until the real history is there.
    func start() {
        guard !started else { return }
        started = true
        track()
        readSaved()
        Task { @MainActor in
            await load(initial: true)
            loadChanges()
        }
    }

    /// Reads the thread (the first time, or again). A thread that could not be read leaves `loadFailed`; one that is
    /// read but shows nothing goes on to older pages.
    private func load(initial: Bool) async {
        guard !reloading else { return }
        reloading = true
        isLoading = true
        loadFailed = false
        onLoadStateChange?()
        if initial, summary.loaded, !server.thread(for: agentID).items.isEmpty {
            // Already read by someone else (the Crew list): nothing to ask.
        } else {
            do {
                try await server.loadHistory(agentID)
            } catch {
                loadFailed = !summary.loaded
            }
        }
        reloading = false
        isLoading = false
        scheduleUpdate()
        onLoadStateChange?()
    }

    private var reloading = false

    /// "Try again" on the screen that says the history could not be read.
    func retryLoad() {
        guard !reloading else { return }
        Task { @MainActor in await load(initial: false) }
    }

    /// Reads the thread again (it could not be read the first time).
    private func reload() {
        guard loadFailed, !reloading else { return }
        Task { @MainActor in await load(initial: false) }
    }

    func stop() {
        started = false
        changesTask?.cancel()
        cacheTask?.cancel()
        cacheTask = nil
        saveNow()
    }

    /// Follows the thread, the queue and the connection: one call per change, which asks for an update and arms itself
    /// again.
    private func track() {
        guard started else { return }
        withObservationTracking {
            let box = summary
            _ = box.thread
            _ = box.loaded
            _ = outbox.revision
            _ = server.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.track()
                // A thread that could not be read comes when the server does.
                if self.loadFailed, self.server.state == .connected { self.reload() }
                self.scheduleUpdate()
            }
        }
    }

    // MARK: width

    /// The list's width and size category. A change measures the rows again.
    func setMetrics(_ new: ChatMetrics) {
        guard new != metrics else { return }
        let first = metrics == nil
        metrics = new
        hostedHeights = [:]
        if first {
            scheduleUpdate()
        } else {
            scheduleUpdate(forceAll: true)
        }
    }

    // MARK: updates

    private var forceAll = false

    func scheduleUpdate(forceAll: Bool = false) {
        if forceAll { self.forceAll = true }
        if updating {
            dirty = true
            return
        }
        updating = true
        Task { @MainActor in
            await runUpdates()
        }
    }

    /// Waits until no update is running or waiting (tests, and the screen when it must show the result).
    func settle() async {
        while updating || dirty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func runUpdates() async {
        repeat {
            dirty = false
            let all = forceAll
            forceAll = false
            await updateOnce(forceAll: all)
        } while dirty
        updating = false
    }

    private func updateOnce(forceAll: Bool) async {
        guard let metrics else { return }
        outbox.releaseEchoes(serverID: server.id, agentID: agentID, thread: summaryThread)
        // The server's thread, or the saved chat while nothing has been read.
        let live = summaryThread
        let useSaved = !summary.loaded && saved != nil
        let thread = useSaved ? saved!.thread : live
        let replies = useSaved ? saved!.replies : live.replies
        var reactions: [Int64: [ChatReactionChip]] = useSaved ? saved!.reactions : live.reactions.mapValues { $0.chips.map(ChatReactionChip.init) }
        // What the person asked for shows at once; it is let go when the thread shows it too.
        for (seq, ask) in wanted {
            if ChatReactionsRules.settled(ask.emoji, in: reactions[seq] ?? []) {
                wanted[seq] = nil
            } else {
                reactions[seq] = ChatReactionsRules.applying(.some(ask.emoji), to: reactions[seq] ?? [])
            }
        }
        let input = ChatRowInput(
            thread: thread, agentName: agentName, primaryRuntime: primaryRuntime,
            queued: outbox.items(serverID: server.id, agentID: agentID), expanded: expanded, changes: changes,
            replies: replies, reactions: reactions, reactionsOn: server.supports("reactions"),
            repliesOn: server.supports("attachments"))
        let built = await Task.detached(priority: .userInitiated) { ChatRowBuilder.build(input) }.value
        // Measure what is new or changed off the main thread; the cards get their height here.
        let old = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let changedRows = built.filter { forceAll || old[$0.id]?.version != $0.version }
        await engine.prefetch(changedRows, metrics)
        var newHeights: [String: CGFloat] = [:]
        newHeights.reserveCapacity(built.count)
        for row in built {
            if row.content.isHosted {
                newHeights[row.id] = hostedHeight(row, width: metrics.width)
            } else {
                newHeights[row.id] = engine.layout(row, metrics).height
            }
        }
        let oldIDs = rows.map(\.id)
        let newIDs = built.map(\.id)
        let changed = built.filter { row in
            guard let previous = old[row.id] else { return false }
            return forceAll || previous.version != row.version
        }.map(\.id)
        let update = ChatUpdate(
            rows: built, heights: newHeights, changed: changed,
            prepended: ThreadPrepend.count(old: oldIDs, new: newIDs), initial: rows.isEmpty && !built.isEmpty)
        let wasEmpty = rows.isEmpty
        rows = built
        heights = newHeights
        updateCount += 1
        findSomethingToShow(built.isEmpty)
        if !isLoading || !built.isEmpty { onUpdate?(update) }
        if wasEmpty != built.isEmpty { onEmptyChange?(built.isEmpty) }
        noteTurn()
        if !useSaved, !built.isEmpty { scheduleSave() }
    }

    /// The newest page held nothing the list draws (only tool calls, say): older pages are read until something shows
    /// (a few at most), so a long history never opens as an empty chat.
    private func findSomethingToShow(_ nothingShows: Bool) {
        guard nothingShows, !isLoading, summary.loaded, hasOlder, server.state == .connected, emptyPages < Self.emptyPageLimit
        else {
            if !nothingShows { emptyPages = 0 }
            return
        }
        emptyPages += 1
        loadOlder()
    }

    private var summaryThread: AgentThread { server.thread(for: agentID) }

    // MARK: cards

    var hostedContent: ((ChatRow) -> AnyView)?

    private func hostedHeight(_ row: ChatRow, width: CGFloat) -> CGFloat {
        let key = "\(row.id)|\(row.version)"
        if let known = hostedHeights[key] { return known }
        let height = sizer.height(width: width) { self.hostedContent?(row) ?? AnyView(EmptyView()) }
        hostedHeights[key] = height
        return height
    }

    private var hostedChanges: [String: CGFloat] = [:]
    private var hostedTask: Task<Void, Never>?

    /// A card says its height changed (an error line appeared in a form). The change is taken a turn of the run loop
    /// later and together with the others: the card says it while the list is being laid out, and the list must not
    /// be changed inside its own layout.
    func hostedHeightChanged(rowID: String, to height: CGFloat) {
        guard abs((heights[rowID] ?? 0) - height) > 0.5 else { return }
        hostedChanges[rowID] = height
        guard hostedTask == nil else { return }
        hostedTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.hostedTask = nil
            var any = false
            for (rowID, height) in self.hostedChanges {
                guard let row = self.rows.first(where: { $0.id == rowID }), abs((self.heights[rowID] ?? 0) - height) > 0.5 else { continue }
                self.hostedHeights["\(row.id)|\(row.version)"] = height
                self.heights[rowID] = height
                any = true
            }
            self.hostedChanges = [:]
            if any { self.onUpdate?(ChatUpdate(rows: self.rows, heights: self.heights, changed: [], prepended: 0, initial: false)) }
        }
    }

    // MARK: actions

    /// Opens or folds a row (a tool group, a scheduled run).
    func toggle(_ rowID: String) {
        if expanded.contains(rowID) { expanded.remove(rowID) } else { expanded.insert(rowID) }
        scheduleUpdate()
    }

    /// Queues a message of the person. Returns false for a message with nothing in it.
    @discardableResult
    func send(_ text: String, attachments: [AgentAttachment] = [], viaButton: Bool = false, replyTo: Int64? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        outbox.enqueue(
            serverID: server.id, agentID: agentID, text: trimmed, attachments: attachments, viaButton: viaButton,
            replyTo: replyTo)
        return true
    }

    /// Asks the agent to stop. Without a connection nothing is sent; the outcome says what happened, so the screen can say so.
    func interrupt() async -> StopOutcome {
        guard server.state == .connected else { return .offline }
        do {
            try await server.interrupt(agentID)
            return .sent
        } catch {
            return StopOutcome.classify(error)
        }
    }

    func retry(queueID: String) { outbox.retry(queueID) }
    func discard(queueID: String) { outbox.discard(queueID) }

    func resend(seq: Int64) {
        Task { _ = try? await server.resendUndelivered(seq, of: agentID) }
    }

    // MARK: older history

    /// Reads the page before the oldest loaded message. The screen keeps what the person reads in place.
    func loadOlder() {
        guard !loadingOlder, server.hasMoreHistory[agentID] == true, server.state == .connected else { return }
        loadingOlder = true
        onLoadStateChange?()
        Task { @MainActor in
            defer {
                loadingOlder = false
                onLoadStateChange?()
            }
            try? await server.loadOlder(agentID)
        }
    }

    var hasOlder: Bool { server.hasMoreHistory[agentID] == true }

    /// The history is being read, or older pages are being read to find something to show: the screen is not empty, it
    /// is waiting.
    var isBusy: Bool {
        isLoading || loadingOlder
            || (rows.isEmpty && emptyPages > 0 && emptyPages < Self.emptyPageLimit && hasOlder && server.state == .connected)
    }

    // MARK: reactions

    /// Puts the emoji on a message (the person's own replaces the one before), or takes it off with nil. The screen shows
    /// it at once; if the daemon refuses, it is taken back and false is returned.
    func react(_ emoji: String?, seq: Int64) async -> Bool {
        guard server.supports("reactions") else { return false }
        let ask = Wanted(emoji: emoji)
        wanted[seq] = ask
        scheduleUpdate()
        do {
            try await server.react(emoji, toMessage: seq, of: agentID)
        } catch {
            if wanted[seq] == ask { wanted[seq] = nil }
            scheduleUpdate()
            return false
        }
        // The daemon's event normally lets the stand-in go; if it never comes the thread's own state is shown again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.wanted[seq] == ask else { return }
            self.wanted[seq] = nil
            self.scheduleUpdate()
        }
        return true
    }

    // MARK: the saved copy

    /// Reads the saved chat off the main thread. It is drawn only while the real history is not read.
    private func readSaved() {
        guard let history, !server.isSynthetic(agentID) else { return }
        let serverID = server.id
        let agent = agentID
        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                history.load(serverID: serverID, agentID: agent)
            }.value
            guard let self, let snapshot, !snapshot.items.isEmpty, !self.summary.loaded else { return }
            self.saved = SavedChat(thread: snapshot.thread, replies: snapshot.replyMap, reactions: snapshot.reactionMap)
            self.scheduleUpdate()
        }
    }

    /// The copy is written a moment after the thread settles (not at every token of a stream).
    private func scheduleSave() {
        guard history != nil, summary.loaded, !server.isSynthetic(agentID) else { return }
        cacheTask?.cancel()
        cacheTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Writes the last items of the thread now, on the main actor and in order (200 items are a few milliseconds; a write left
    /// to another task could be cut off when the app is suspended, or land after a newer one).
    func saveNow() {
        guard let history, summary.loaded, !server.isSynthetic(agentID) else { return }
        let thread = summaryThread
        guard !thread.items.isEmpty else { return }
        history.save(
            ChatHistorySnapshot(thread: thread, now: Int64(Date().timeIntervalSince1970 * 1000)), serverID: server.id,
            agentID: agentID)
    }

    // MARK: changes

    /// A turn that ended brings the changes card: the files the agent changed since the last checkpoint.
    private func noteTurn() {
        let running = summaryThread.turnRunning
        if lastTurnRunning, !running { loadChanges() }
        lastTurnRunning = running
    }

    func loadChanges() {
        guard server.supports("changes"), server.state == .connected else { return }
        changesTask?.cancel()
        changesTask = Task { @MainActor in
            guard let diff = try? await server.changesDiff(agentID: agentID), !Task.isCancelled else { return }
            let summary = diff.files.isEmpty ? nil : ChatChangesSummary(files: diff.files.count, additions: diff.additions, deletions: diff.deletions)
            if summary != changes {
                changes = summary
                scheduleUpdate()
            }
        }
    }
}

/// Measures a SwiftUI card by hosting it once, off screen.
@MainActor
final class ChatHostedSizer {
    func height(width: CGFloat, content: () -> AnyView) -> CGFloat {
        ChatCounters.shared.hostedSized()
        let host = UIHostingController(rootView: content())
        host.sizingOptions = []
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(max(size.height, 1))
    }
}

/// What a stop of the agent came to: the request went out (`sent`, also when the agent had already stopped), there is no
/// connection to send it over (`offline`), or the daemon refused it (`failed`).
enum StopOutcome: Equatable {
    case sent
    case offline
    case failed

    /// The outcome of a stop the daemon refused. The daemon says "agent <id> stopped" when the agent is no longer running:
    /// that is the stop the person asked for, so it counts as sent. Any other error is a failure.
    static func classify(_ error: Error) -> StopOutcome {
        guard let rpc = error as? RPCError else { return .failed }
        let message = rpc.message.lowercased()
        return message.contains("stopped") || message.contains("not running") ? .sent : .failed
    }
}
