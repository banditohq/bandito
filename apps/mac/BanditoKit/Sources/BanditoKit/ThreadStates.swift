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
    /// Approvals in the thread that wait for an answer.
    public private(set) var pendingApprovalCount = 0
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

    nonisolated init() {}

    func summarize() {
        let status: AgentStatus? = loaded ? thread.status : nil
        if loadedStatus != status { loadedStatus = status }
        if statusDetail != thread.statusDetail { statusDetail = thread.statusDetail }
        if turnRunning != thread.turnRunning { turnRunning = thread.turnRunning }
        if turnStartedAt != thread.turnStartedAt { turnStartedAt = thread.turnStartedAt }
        if isEmpty != thread.items.isEmpty { isEmpty = thread.items.isEmpty }
        // One pass over the items for the rest.
        var approvals = 0
        var forms: [FormRow] = []
        var connects: [ConnectRow] = []
        var connectCards = 0
        var tools: [ToolRow] = []
        for item in thread.items {
            switch item {
            case .approval(let row) where row.state == .pending: approvals += 1
            case .form(let row) where row.isPending: forms.append(row)
            case .connect(let row):
                connectCards += 1
                if row.isPending { connects.append(row) }
            case .tool(let row) where row.ok == nil: tools.append(row)
            default: break
            }
        }
        if pendingApprovalCount != approvals { pendingApprovalCount = approvals }
        if pendingForms != forms { pendingForms = forms }
        if pendingConnects != connects { pendingConnects = connects }
        if connectCardCount != connectCards { connectCardCount = connectCards }
        if unfinishedTools != tools { unfinishedTools = tools }
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
