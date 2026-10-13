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
    private(set) var isLoading = true
    private(set) var loadFailed = false
    private(set) var loadingOlder = false
    /// Called with what changed. Set by the screen.
    var onUpdate: ((ChatUpdate) -> Void)?
    /// Called when the list has nothing to draw yet or no more: the empty state shows.
    var onEmptyChange: ((Bool) -> Void)?

    private(set) var metrics: ChatMetrics?
    private var updating = false
    private var dirty = false
    private var started = false
    private var changesTask: Task<Void, Never>?
    private var lastTurnRunning = false
    private var hostedHeights: [String: CGFloat] = [:]
    private let sizer = ChatHostedSizer()
    private var updateCount = 0

    init(server: ServerModel, agentID: String, engine: ChatLayoutEngine = .shared, outbox: ChatOutbox = .shared) {
        self.server = server
        self.agentID = agentID
        self.engine = engine
        self.outbox = outbox
    }

    var agentName: String { server.agents.first { $0.id == agentID }?.name ?? "" }
    private var primaryRuntime: String { server.agents.first { $0.id == agentID }?.runtime.rawValue ?? "" }
    var summary: AgentThreadState { server.threadSummary(for: agentID) }

    /// The number of updates made so far (tests wait on it).
    var updates: Int { updateCount }

    // MARK: life

    /// Loads the thread when it is not loaded, and starts following it.
    func start() {
        guard !started else { return }
        started = true
        track()
        Task { @MainActor in
            if !summary.loaded || server.thread(for: agentID).items.isEmpty {
                do {
                    try await server.loadHistory(agentID)
                } catch {
                    loadFailed = !summary.loaded
                }
            }
            isLoading = false
            scheduleUpdate()
            loadChanges()
        }
    }

    /// Reads the thread again (it could not be read the first time).
    private func reload() {
        loadFailed = false
        Task { @MainActor in
            do {
                try await server.loadHistory(agentID)
            } catch {
                loadFailed = !summary.loaded
            }
            scheduleUpdate()
        }
    }

    func stop() {
        started = false
        changesTask?.cancel()
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
        let input = ChatRowInput(
            thread: summaryThread, agentName: agentName, primaryRuntime: primaryRuntime,
            queued: outbox.items(serverID: server.id, agentID: agentID), expanded: expanded, changes: changes)
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
        if !isLoading || !built.isEmpty { onUpdate?(update) }
        if wasEmpty != built.isEmpty { onEmptyChange?(built.isEmpty) }
        noteTurn()
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
    func send(_ text: String, attachments: [AgentAttachment] = [], viaButton: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        outbox.enqueue(
            serverID: server.id, agentID: agentID, text: trimmed, attachments: attachments, viaButton: viaButton)
        return true
    }

    func interrupt() {
        Task { try? await server.interrupt(agentID) }
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
        Task { @MainActor in
            defer { loadingOlder = false }
            try? await server.loadOlder(agentID)
        }
    }

    var hasOlder: Bool { server.hasMoreHistory[agentID] == true }

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
