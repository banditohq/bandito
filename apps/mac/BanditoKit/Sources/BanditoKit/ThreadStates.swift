import Foundation
import Observation

/// One agent's thread and what the team shows of it, observed on its own (see `ServerModel.threads`).
@MainActor
@Observable
public final class AgentThreadState {
    /// The thread. Changes at every event of the agent, a streamed token included.
    public internal(set) var thread = AgentThread() {
        didSet { summarize() }
    }

    /// Whether a thread was loaded or built from events (a box made only by a read holds an empty one).
    public internal(set) var loaded = false

    // The summary: what the chat's frame (header, composer, banners) and the team show of the thread. Each is written
    // only when its value changes, so a streamed token, which changes only the last item, redraws none of their readers.

    /// The thread's status, nil until a thread is loaded.
    public private(set) var loadedStatus: AgentStatus?
    /// What the daemon said with the status (an error's reason).
    public private(set) var statusDetail: String?
    /// Approvals in the thread that wait for an answer, and the title of the oldest.
    public private(set) var pendingApprovalCount = 0
    public private(set) var firstPendingApprovalTitle: String?
    /// A turn runs, and since when (Unix ms).
    public private(set) var turnRunning = false
    public private(set) var turnStartedAt: Int64?
    /// The thread has no item.
    public private(set) var isEmpty = true
    /// The forms and the service requests that wait for the person, oldest first.
    public private(set) var pendingForms: [FormRow] = []
    public private(set) var pendingConnects: [ConnectRow] = []
    /// How many service requests (connect cards) the thread holds, answered or not.
    public private(set) var connectCardCount = 0
    /// Tool calls without a result yet, oldest first.
    public private(set) var unfinishedTools: [ToolRow] = []
    /// The start of the newest message (a stream included), for a one-line preview. Only the start is kept: a stream
    /// stops changing it once it is longer than a preview can show.
    public private(set) var lastMessageHead: String?
    /// The time of the newest item that has one (Unix ms).
    public private(set) var lastItemTimestamp: Int64?

    /// How much of the newest message `lastMessageHead` keeps.
    public static let previewLength = 240
    /// While a reply streams, `lastMessageHead` follows it at most this often (the team list's rows read it: they were
    /// rebuilt at every token of the first 240 characters). The settled message is written at once.
    public nonisolated(unsafe) static var streamPreviewInterval: Duration = .milliseconds(300)

    /// This box's own interval (tests); nil: `streamPreviewInterval`.
    @ObservationIgnored var previewInterval: Duration?
    @ObservationIgnored private var headWrittenAt: ContinuousClock.Instant?
    @ObservationIgnored private var headTask: Task<Void, Never>?

    nonisolated init() {}

    func summarize() {
        let status: AgentStatus? = loaded ? thread.status : nil
        if loadedStatus != status { loadedStatus = status }
        if statusDetail != thread.statusDetail { statusDetail = thread.statusDetail }
        if turnRunning != thread.turnRunning { turnRunning = thread.turnRunning }
        if turnStartedAt != thread.turnStartedAt { turnStartedAt = thread.turnStartedAt }
        if isEmpty != thread.items.isEmpty { isEmpty = thread.items.isEmpty }
        updateHead()
        let stamp = thread.items.reversed().lazy.compactMap(\.timestamp).first
        if lastItemTimestamp != stamp { lastItemTimestamp = stamp }
        // One pass over the items for the rest.
        var approvals = 0
        var firstApprovalTitle: String?
        var forms: [FormRow] = []
        var connects: [ConnectRow] = []
        var connectCards = 0
        var tools: [ToolRow] = []
        for item in thread.items {
            switch item {
            case .approval(let row) where row.state == .pending:
                if approvals == 0 { firstApprovalTitle = row.title }
                approvals += 1
            case .form(let row) where row.isPending: forms.append(row)
            case .connect(let row):
                connectCards += 1
                if row.isPending { connects.append(row) }
            case .tool(let row) where row.ok == nil: tools.append(row)
            default: break
            }
        }
        if pendingApprovalCount != approvals { pendingApprovalCount = approvals }
        if firstPendingApprovalTitle != firstApprovalTitle { firstPendingApprovalTitle = firstApprovalTitle }
        if pendingForms != forms { pendingForms = forms }
        if pendingConnects != connects { pendingConnects = connects }
        if connectCardCount != connectCards { connectCardCount = connectCards }
        if unfinishedTools != tools { unfinishedTools = tools }
    }

    /// Writes the preview's head: at once for a settled message, at most once per `streamPreviewInterval` for a stream
    /// (the latest text after the wait).
    private func updateHead() {
        let head = thread.lastMessageText.map { String($0.prefix(Self.previewLength)) }
        guard lastMessageHead != head else { return }
        let now = ContinuousClock.now
        if thread.lastMessageIsStreaming, let written = headWrittenAt,
            let wait = StreamPreviewThrottle.wait(since: written, now: now, interval: previewInterval ?? Self.streamPreviewInterval)
        {
            guard headTask == nil else { return }
            headTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.headTask = nil
                self.updateHead()
            }
            return
        }
        headTask?.cancel()
        headTask = nil
        lastMessageHead = head
        headWrittenAt = now
    }
}

/// When a streamed preview may be written again. Pure, for the tests.
public enum StreamPreviewThrottle {
    /// Nil: now. Else how long to wait.
    public static func wait(
        since written: ContinuousClock.Instant, now: ContinuousClock.Instant, interval: Duration
    ) -> Duration? {
        let elapsed = now - written
        return elapsed >= interval ? nil : interval - elapsed
    }
}

/// The threads of a server's agents, by agent id. The boxes are made on first use, a read included: a view that read a
/// thread before it was loaded is told when it comes.
@MainActor
public final class ThreadStates {
    private var boxes: [String: AgentThreadState] = [:]

    nonisolated init() {}

    /// The box of `agentId`, made when it is missing.
    public func box(_ agentId: String) -> AgentThreadState {
        if let box = boxes[agentId] { return box }
        let box = AgentThreadState()
        boxes[agentId] = box
        return box
    }

    /// The loaded thread of `agentId`, or nil. Setting nil empties the box (its readers see that).
    public internal(set) subscript(agentId: String) -> AgentThread? {
        get {
            let box = box(agentId)
            return box.loaded ? box.thread : nil
        }
        set {
            let box = box(agentId)
            if let newValue {
                box.loaded = true
                box.thread = newValue
            } else {
                box.loaded = false
                box.thread = AgentThread()
            }
        }
    }

    subscript(agentId: String, default value: @autoclosure () -> AgentThread) -> AgentThread {
        get { self[agentId] ?? value() }
        set { self[agentId] = newValue }
    }
}
