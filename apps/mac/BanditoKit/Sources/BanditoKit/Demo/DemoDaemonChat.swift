import Foundation

// What the demo daemon adds for a chat: a hook that lets the app's demo answer a message (the scripted reply of the
// iPhone's `-demo`), the changes of an agent's folder, and a saved attachment. Nothing is written anywhere.

/// A call from the person to an agent that the demo's script may answer.
public struct DemoClientCall: Sendable, Equatable {
    /// `agents.send`, `agents.interrupt`, `approvals.resolve` or `forms.answer`.
    public var method: String
    public var agentID: String
    /// The message of `agents.send`.
    public var text: String?
    /// The approval or the form that was answered.
    public var objectID: String?
    /// `allow` or `deny`, for an approval.
    public var decision: String?

    public init(method: String, agentID: String, text: String? = nil, objectID: String? = nil, decision: String? = nil) {
        self.method = method
        self.agentID = agentID
        self.text = text
        self.objectID = objectID
        self.decision = decision
    }
}

extension DemoDaemonTransport {
    /// Sets what happens when the person writes to an agent, stops it, or answers one of its requests. The hook runs
    /// after the daemon's own events for the call (the person's message and the agent's status); it answers with
    /// `emitEvent`. Nil removes it.
    public func setClientHook(_ hook: (@Sendable (DemoClientCall) -> Void)?) {
        clientHook = hook
    }

    /// The demo's changes: twelve files with 240 lines added and 30 removed, and a diff for each.
    public static let changedFiles: [(path: String, status: String, additions: Int, deletions: Int)] = [
        ("Sources/App/ThreadView.swift", "modified", 62, 8),
        ("Sources/App/Composer.swift", "modified", 48, 6),
        ("Sources/App/ChatModel.swift", "added", 41, 0),
        ("Sources/App/MessageBlocks.swift", "modified", 22, 4),
        ("Sources/App/QuickReplies.swift", "modified", 17, 3),
        ("Sources/App/SendQueue.swift", "added", 15, 0),
        ("Tests/AppTests/ChatTests.swift", "added", 12, 0),
        ("Tests/AppTests/QueueTests.swift", "added", 9, 0),
        ("Sources/App/Legacy.swift", "deleted", 0, 5),
        ("README.md", "modified", 6, 2),
        ("Package.swift", "modified", 5, 1),
        ("i18n/en.json", "modified", 3, 1),
    ]

    /// The unified diff the demo shows for one changed file.
    static func demoDiff(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return """
            diff --git a/\(path) b/\(path)
            --- a/\(path)
            +++ b/\(path)
            @@ -10,6 +10,8 @@ struct \((name as NSString).deletingPathExtension) {
                 let id: String
                 var title: String
            -    var isRunning = false
            +    var isRunning = false
            +    var queued = 0
            +    var failed = 0
                 var rows: [Row] = []
            
                 func reload() {
            @@ -41,4 +43,6 @@ extension \((name as NSString).deletingPathExtension) {
                     rows = build(items)
            -        apply(rows)
            +        let changed = diff(rows, old)
            +        apply(changed)
            +        report(changed.count)
                 }
             }
            """
    }

    /// Answers `changes.diff`, `changes.file`, `changes.checkpoints` and `attachments.upload`; nil for any other method.
    func answerChat(_ method: String, _ params: [String: Any], now: Int64) -> Result<String, RPCError>? {
        switch method {
        case "changes.diff":
            let files = Self.changedFiles.map { file -> [String: Any] in
                ["path": file.path, "status": file.status, "additions": file.additions, "deletions": file.deletions]
            }
            return .success(DemoJSON.text(["from": "demo-before", "to": NSNull(), "files": files]))
        case "changes.file":
            return .success(DemoJSON.text(["diff": Self.demoDiff(path: params["path"] as? String ?? "file"), "truncated": false]))
        case "changes.checkpoints":
            return .success("[]")
        case "attachments.upload":
            let name = params["name"] as? String ?? "file"
            let size = (params["data_base64"] as? String).map { ($0.utf8.count * 3) / 4 } ?? 0
            let agent = params["agent_id"] as? String ?? "agent"
            let ext = (name as NSString).pathExtension.lowercased()
            let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic"][ext] ?? "application/octet-stream"
            return .success(
                DemoJSON.text(["path": "/Users/demo/.bandito/attachments/\(agent)/\(name)", "name": name, "size": size, "mime": mime]))
        default:
            return nil
        }
    }
}
