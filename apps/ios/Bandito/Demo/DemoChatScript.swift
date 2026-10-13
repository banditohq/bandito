import BanditoKit
import Foundation

/// What the demo agents do when the person writes to them (`-demo`): a turn that reads, runs a few commands, asks for an
/// approval when it is Forge, streams a reply with a list and a code block, and offers two buttons. It speaks through the
/// demo daemon (`DemoDaemonTransport.setClientHook`), so the chat is the real one, fed by the same events a daemon sends.
/// Nothing leaves the process.
final class DemoChatScript: @unchecked Sendable {
    private let transport: DemoDaemonTransport
    private let lock = NSLock()
    private var running: [String: Task<Void, Never>] = [:]
    private var waiting: [String: (agent: String, text: String)] = [:]
    private var turns = 0

    /// Pause between steps; the tests make it short.
    var pace: Duration = .milliseconds(280)
    /// Pause between two pieces of the streamed reply.
    var tokenPace: Duration = .milliseconds(22)

    init(transport: DemoDaemonTransport) {
        self.transport = transport
    }

    func handle(_ call: DemoClientCall) {
        switch call.method {
        case "agents.send":
            guard let text = call.text else { return }
            start(agent: call.agentID, text: text)
        case "agents.interrupt":
            interrupt(agent: call.agentID)
        case "approvals.resolve":
            guard let id = call.objectID else { return }
            resume(approval: id, allowed: call.decision == "allow")
        default:
            return
        }
    }

    private func start(agent: String, text: String) {
        let number: Int = lock.withLock {
            turns += 1
            return turns
        }
        let task = Task { [self] in
            await run(agent: agent, text: text, number: number)
        }
        lock.withLock {
            running[agent]?.cancel()
            running[agent] = task
        }
    }

    private func interrupt(agent: String) {
        let task = lock.withLock { running.removeValue(forKey: agent) }
        task?.cancel()
        Task { [transport] in
            await transport.emitEvent(
                agentID: agent, kind: "turn.completed", payload: ["turn_id": "demo-turn-stop", "status": "interrupted"], persisted: false)
            await transport.emitEvent(agentID: agent, kind: "agent.status", payload: ["status": "idle"], persisted: false)
        }
    }

    private func resume(approval id: String, allowed: Bool) {
        guard let entry = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
        let task = Task { [self] in
            await finish(agent: entry.agent, text: entry.text, number: 0, allowed: allowed)
        }
        lock.withLock { running[entry.agent] = task }
    }

    // MARK: the turn

    private func emit(_ agent: String, _ kind: String, _ payload: sending [String: Any]) async {
        // The daemon's record of the agent follows its status, as a real daemon's does.
        if kind == "agent.status", let status = payload["status"] as? String {
            await transport.setAgentStatus(agent, status)
        }
        await transport.emitEvent(agentID: agent, kind: kind, payload: payload, persisted: false)
    }

    private func run(agent: String, text: String, number: Int) async {
        let turn = "demo-turn-\(number)"
        await emit(agent, "turn.started", ["turn_id": turn, "source": "user"])
        guard await pause() else { return }
        let steps: [(tool: String, title: String, output: String)] = [
            ("Read", "Read Sources/App/SendQueue.swift", "142 lines"),
            ("bash", "git status --short", " M Sources/App/SendQueue.swift"),
            ("bash", "swift build -q", "Build complete"),
        ]
        for (index, step) in steps.enumerated() {
            let call = "demo-call-\(number)-\(index)"
            await emit(agent, "tool.call", ["call_id": call, "tool": step.tool, "title": step.title, "input": [String: String]()])
            guard await pause() else { return }
            await emit(agent, "tool.result", ["call_id": call, "ok": true, "output": step.output])
            guard await pause(0.6) else { return }
        }
        if text.lowercased().contains("test") || text.lowercased().contains("push") || text.lowercased().contains("approve") {
            let id = "demo-script-approval-\(number)"
            await transport.link(id, toAgent: agent)
            lock.withLock { waiting[id] = (agent, text) }
            await emit(
                agent, "approval.requested",
                [
                    "approval_id": id, "call_id": "demo-call-\(number)-t", "tool": "bash", "title": "swift test -q",
                    "command": "swift test -q", "reason": "approval required for every action",
                ])
            await emit(agent, "agent.status", ["status": "needs_you"])
            return
        }
        await finish(agent: agent, text: text, number: number, allowed: true)
    }

    private func finish(agent: String, text: String, number: Int, allowed: Bool) async {
        let turn = "demo-turn-\(number)"
        await emit(agent, "agent.status", ["status": "working"])
        if allowed {
            let call = "demo-call-\(number)-run"
            await emit(agent, "tool.call", ["call_id": call, "tool": "bash", "title": "swift test -q", "input": [String: String]()])
            guard await pause(0.6) else { return }
            await emit(agent, "tool.result", ["call_id": call, "ok": true, "output": "Executed 214 tests, with 0 failures"])
            guard await pause() else { return }
        }
        let reply = allowed ? Self.reply : Self.declinedReply
        for piece in Self.pieces(of: reply) {
            guard await pause(tokenPace) else { return }
            await emit(agent, "message.delta", ["text": piece])
        }
        await emit(agent, "message.assistant", ["text": reply])
        await emit(
            agent, "agent.quick_replies",
            ["buttons": [["label": "Push the branch", "reply": "Yes, push the branch."], ["label": "Show the diff", "reply": "Show me the diff first."]]])
        await emit(agent, "turn.completed", ["turn_id": turn, "status": "ok"])
        await emit(agent, "agent.status", ["status": "idle"])
        lock.withLock { running[agent] = nil }
    }

    private func pause(_ seconds: Double = 0) async -> Bool {
        await pause(seconds == 0 ? pace : .milliseconds(Int(seconds * 1000)))
    }

    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    // MARK: words

    static let reply = """
        Done. The queue now **retries** a send that dropped midway, and the tests pass.

        ## What changed
        - `SendQueue.swift` keeps the message until the server answers
        - a message is not sent twice when the link comes back
        - the tests cover the order and the retry

        ```swift
        func retry(_ id: String) {
            queue.retry(id)
            pump()
        }
        ```

        The details are in the [design notes](https://bandito.dev/docs). Say the word and I push the branch.
        """

    static let declinedReply = "Understood, I did not run the tests. The change is in place; tell me when you want them run."

    /// The reply cut into pieces the way a model streams it: a word and its space at a time.
    static func pieces(of text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
