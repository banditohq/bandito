import Foundation

// A daemon that lives inside the app, for the smoothness check (Help menu, with ⌥): every screen gets the answers a
// real daemon would give (its catalogs are the daemon's own files, see `Resources/DemoDaemon`), and nothing leaves the
// process. No real server, folder, terminal or account is touched.

/// What the demo daemon knows about the world it pretends to run on.
public struct DemoDaemonSetup: Sendable {
    /// The agents shown by the app, for the workspace that holds them (the app installs them itself).
    public var agentIDs: [String]
    /// The host name the daemon reports (the second demo server has another one).
    public var hostname: String

    public init(agentIDs: [String] = [], hostname: String = "demo") {
        self.agentIDs = agentIDs
        self.hostname = hostname
    }
}

/// The folders of the demo daemon's files.
public enum DemoDaemonFiles {
    public static let home = "/Users/demo"
    public static let projects = "/Users/demo/Projects"
    /// A folder of 2 000 entries: the long list of the Files scenario.
    public static let bigFolder = "/Users/demo/Projects/assets"
    public static let bigFolderCount = 2_000
    /// A code file of about 1 200 lines, for the viewer.
    public static let codeFile = "/Users/demo/Projects/bandito-site/src/ThreadView.swift"
    public static let terminalID = "demo-term-1"
}

/// An in-memory `RPCTransport` that answers like a daemon. Requests are answered as soon as they are sent; terminal
/// output is pushed by `emitTerminalOutput`.
public actor DemoDaemonTransport: RPCTransport {
    private let setup: DemoDaemonSetup
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let inbound: DemoInbound
    private let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
    /// Bytes written to each terminal so far.
    private var terminalOffsets: [String: UInt64] = [:]
    private var terminalSizes: [String: (cols: Int, rows: Int)] = [:]
    private var closed = false
    private var lineCounter = 0
    /// The agents the daemon holds, in wire form (`agents.create`, the app's own agents through `remember`).
    var demoAgents: [[String: Any]] = []
    /// The schedules the daemon holds, in wire form (`schedules.create`, `rememberSchedule`).
    var demoSchedules: [[String: Any]] = []
    /// The folders `fs.mkdir` made, by path: a name taken answers `exists`, and the folder is listed from then on.
    var demoFolders: [String] = []
    /// The templates `agents.create_bundle` answers with an `error` (see `failBundleEntry`).
    var demoBundleFailures: Set<String> = []

    public init(setup: DemoDaemonSetup = DemoDaemonSetup()) {
        self.setup = setup
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self, throwing: Error.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        inbound = DemoInbound(stream.makeAsyncIterator())
    }

    public func connect() async throws {}

    public func send(_ text: String) async throws {
        guard !closed else { throw RPCError(code: RPCError.disconnected, message: "demo daemon closed") }
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        // A notification from the client (no id) needs no answer.
        guard let id = object["id"] as? Int else { return }
        switch answer(method, params) {
        case .success(let result):
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}")
            followUp(method, params)
        case .failure(let error):
            var body: [String: Any] = ["code": error.code, "message": error.message]
            if let reason = error.data?["reason"]?.string { body["data"] = ["reason": reason] }
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"error\":\(DemoJSON.text(body))}")
        }
    }

    /// Which agent an approval, a form or a connect request belongs to: the events the daemon sends after an answer name
    /// the agent. The app's demo registers its requests here (`link`).
    private var owners: [String: String] = [:]

    /// Names the agent a request belongs to, so the answer to it can come back as the agent's event.
    public func link(_ objectID: String, toAgent agentID: String) {
        owners[objectID] = agentID
    }

    /// The events the daemon sends after an answer: the request ends, and a message the person sent reaches the agent.
    /// They carry no `seq` (a live event the model applies at once); the demo's seqs belong to its seeded threads.
    private func followUp(_ method: String, _ params: [String: Any]) {
        switch method {
        case "approvals.resolve":
            guard let id = params["approval_id"] as? String, let agent = owners[id] else { return }
            emitEvent(
                agentID: agent, kind: "approval.resolved",
                payload: [
                    "approval_id": id, "decision": params["decision"] ?? "deny", "by": "user",
                    "remember": params["remember"] ?? false,
                ],
                persisted: false)
        case "forms.answer":
            guard let id = params["form_id"] as? String, let agent = owners[id] else { return }
            var payload: [String: Any] = ["form_id": id, "action": params["action"] ?? "expired"]
            for key in ["values", "comment", "message"] {
                if let value = params[key] { payload[key] = value }
            }
            emitEvent(agentID: agent, kind: "form_answered", payload: payload, persisted: false)
        case "integrations.request_decline":
            guard let id = params["request_id"] as? String, let agent = owners[id] else { return }
            emitEvent(
                agentID: agent, kind: "integration_request_ended", payload: ["request_id": id, "status": "declined"],
                persisted: false)
        case "agents.send":
            guard let agent = params["agent_id"] as? String, let text = params["text"] as? String else { return }
            emitEvent(
                agentID: agent, kind: "message.user",
                payload: ["text": text, "source": "user", "via_button": params["via_button"] ?? false], persisted: false)
            emitEvent(agentID: agent, kind: "agent.status", payload: ["status": "working"], persisted: false)
        default:
            return
        }
    }

    public func receive() async throws -> String {
        guard let line = try await inbound.next() else {
            throw RPCError(code: RPCError.disconnected, message: "demo daemon closed")
        }
        return line
    }

    public func close() async {
        closed = true
        continuation.finish()
    }

    /// Pushes `lines` lines of build output into the terminal `id`, as one `term.output` notification (a busy command
    /// such as a build or `cat` of a long log).
    public func emitTerminalOutput(id: String = DemoDaemonFiles.terminalID, lines: Int) {
        guard !closed, lines > 0 else { return }
        var text = ""
        text.reserveCapacity(lines * 72)
        for _ in 0..<lines {
            lineCounter += 1
            let n = lineCounter
            let kind = ["Compiling", "Linking", "Checking", "Testing"][n % 4]
            text += "\u{1B}[32m\(kind)\u{1B}[0m module\(n % 97)/Source\(n % 211).swift (\(n % 13).\(n % 10)s) [\(n)/10000]\r\n"
        }
        let bytes = Data(text.utf8)
        let offset = terminalOffsets[id, default: 0]
        terminalOffsets[id] = offset + UInt64(bytes.count)
        let params = DemoJSON.text(["id": id, "offset": offset, "data": bytes.base64EncodedString()])
        continuation.yield("{\"jsonrpc\":\"2.0\",\"method\":\"term.output\",\"params\":\(params)}")
    }

    /// The last persisted event the demo daemon sent (`events.subscribe` answers 1).
    private var eventSeq: Int64 = 1

    /// Sends a live event of an agent, as the daemon does while the agent works: `persisted` events take the next `seq`,
    /// the others (`message.delta`) carry 0.
    public func emitEvent(agentID: String, kind: String, payload: [String: Any], persisted: Bool) {
        guard !closed else { return }
        var seq: Int64 = 0
        if persisted {
            eventSeq += 1
            seq = eventSeq
        }
        let event: [String: Any] = [
            "seq": seq, "agent_id": agentID, "ts": Int64(Date().timeIntervalSince1970 * 1000), "kind": kind,
            "payload": payload,
        ]
        continuation.yield("{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":\(DemoJSON.text(event))}")
    }

    // MARK: answers

    private func answer(_ method: String, _ params: [String: Any]) -> Result<String, RPCError> {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let reply = answerAgents(method, params, now: now) {
            return reply
        }
        switch method {
        case "daemon.hello", "daemon.info":
            return .success(DemoJSON.text(daemonInfo(now: now)))
        case "events.subscribe":
            return .success("{\"last_seq\":\(eventSeq)}")
        case "events.page", "events.since", "history.search", "history.day":
            return .success("[]")
        case "runtimes.status":
            return .success(DemoJSON.text(runtimes))
        case "runtimes.models":
            return .success(DemoJSON.text(runtimeModels(now: now)))
        case "usage.limits", "usage.refresh":
            return .success(DemoJSON.text(usage(now: now)))
        case "integrations.catalog":
            return .success(DemoCatalogs.shared.integrations)
        case "skills.catalog":
            return .success(DemoCatalogs.shared.skills)
        case "agents.templates":
            return .success(DemoCatalogs.shared.templates)
        case "agents.bundles":
            return .success(DemoCatalogs.shared.bundles)
        case "integrations.list":
            return .success(DemoJSON.text(integrations(now: now)))
        case "integrations.call_stats", "integrations.recommend", "commands.list", "forms.list", "rules.list",
            "schedules.agent.list", "approvals.list", "secrets.list", "crew.list", "team.list":
            return .success("[]")
        case "fs.list":
            return listing(params["path"] as? String ?? "~", now: now)
        case "fs.stat":
            return stat(params["path"] as? String ?? "", now: now)
        case "fs.mkdir":
            return mkdir(params["path"] as? String ?? "", now: now)
        case "fs.read":
            return read(params["path"] as? String ?? "", now: now)
        case "fs.projects":
            return .success(DemoJSON.text(projects(now: now)))
        case "fs.search":
            let query = (params["query"] as? String ?? "").lowercased()
            let found = bigFolderEntries(now: now).filter { ($0["name"] as? String ?? "").lowercased().contains(query) }
            return .success(DemoJSON.text(Array(found.prefix(200))))
        case "term.list":
            return .success(DemoJSON.text([terminal(DemoDaemonFiles.terminalID, now: now)]))
        case "term.open":
            let id = "demo-term-\(terminalOffsets.count + 2)"
            terminalOffsets[id] = 0
            return .success(DemoJSON.text(terminal(id, now: now)))
        case "term.attach":
            let id = params["id"] as? String ?? DemoDaemonFiles.terminalID
            let prompt = Data("demo@bandito ~/Projects/bandito-site % ".utf8)
            if terminalOffsets[id] == nil { terminalOffsets[id] = UInt64(prompt.count) }
            let start = terminalOffsets[id, default: 0] - min(terminalOffsets[id, default: 0], UInt64(prompt.count))
            return .success(DemoJSON.text(["start": start, "data": prompt.base64EncodedString()]))
        case "term.resize":
            let id = params["id"] as? String ?? DemoDaemonFiles.terminalID
            terminalSizes[id] = (params["cols"] as? Int ?? 120, params["rows"] as? Int ?? 32)
            return .success(DemoJSON.text(terminal(id, now: now)))
        case "term.rename":
            return .success(DemoJSON.text(terminal(params["id"] as? String ?? DemoDaemonFiles.terminalID, now: now)))
        case "term.input", "term.detach", "term.close":
            return .success("null")
        case "host.stats":
            return .success(DemoJSON.text(hostStats(now: now)))
        case "host.history":
            return .success(DemoJSON.text(["points": hostHistory(range: params["range"] as? String ?? "1h", now: now)]))
        case "host.processes":
            return .success(DemoJSON.text(processes))
        case "host.ports":
            return .success(DemoJSON.text(ports))
        case "workspaces.list":
            return .success(DemoJSON.text(workspaces))
        case "devices.list":
            return .success(DemoJSON.text(devices(now: now)))
        case "backups.list":
            return .success(DemoJSON.text(backups(now: now)))
        case "server.settings_get":
            return .success(DemoJSON.text(serverSettings))
        case "telegram.status":
            return .success(
                "{\"bot\":null,\"chats\":[],\"configured\":false,\"last_error\":null,\"running\":false}")
        case "daemon.logs":
            return .success(DemoJSON.text(["source": "file", "lines": logLines(now: now)]))
        case "daemon.update_check":
            return .success(DemoJSON.text(["available": false, "checked_at": now, "current": DemoDaemon.version]))
        case "setup.status":
            return .success(DemoJSON.text(setupStatus))
        case "browser.status":
            return .success("{\"cdp\":null,\"controller\":null,\"pid\":null,\"running\":false,\"started_at\":null}")
        case "approvals.resolve", "forms.answer", "integrations.request_decline", "agents.send":
            // The answer is accepted; the event that follows (`followUp`) is what the app folds in.
            return .success("{}")
        case "screen.status":
            return .failure(
                RPCError(
                    code: -32025, message: "the server screen needs Linux (Xvfb and x11vnc)",
                    data: .object(["reason": .string("unsupported")])))
        default:
            return .failure(RPCError(code: RPCError.methodNotFound, message: "unknown method \(method)"))
        }
    }

    // MARK: daemon and runtimes

    private func daemonInfo(now: Int64) -> [String: Any] {
        [
            "version": DemoDaemon.version, "hostname": setup.hostname, "os": "macos", "arch": "aarch64",
            "pid": 4242, "started_at": startedAt, "last_seq": eventSeq, "features": DemoDaemon.features,
            "last_restore": NSNull(), "safe_mode": false, "safe_mode_error": NSNull(),
            "update": ["available": false, "checked_at": now, "current": DemoDaemon.version, "latest": DemoDaemon.version],
        ]
    }

    private var runtimes: [[String: Any]] {
        [
            [
                "kind": "claude", "installed": true, "logged_in": true, "version": "2.1.300 (Claude Code)",
                "detail": NSNull(), "supported_capabilities": ["terminal", "files", "browser", "team", "screen"],
            ],
            [
                "kind": "codex", "installed": true, "logged_in": true, "version": "codex-cli 0.170.0",
                "detail": NSNull(), "supported_capabilities": ["browser", "team", "screen"],
            ],
            [
                "kind": "grok", "installed": true, "logged_in": NSNull(), "version": "grok 1.1.0",
                "detail": NSNull(), "supported_capabilities": ["browser", "team", "screen"],
            ],
        ]
    }

    private func runtimeModels(now: Int64) -> [[String: Any]] {
        func model(_ id: String, _ name: String, _ description: String, _ isDefault: Bool) -> [String: Any] {
            [
                "id": id, "name": name, "description": description, "is_default": isDefault,
                "context_window": 200_000, "efforts": ["low", "medium", "high", "max"],
            ]
        }
        return [
            [
                "runtime": "claude", "fetched_at": now, "error": NSNull(),
                "models": [
                    model("opus", "Opus", "For complex work and everyday tasks", true),
                    model("sonnet", "Sonnet", "Efficient for routine tasks", false),
                    model("haiku", "Haiku", "Fastest for quick answers", false),
                ],
            ],
            [
                "runtime": "codex", "fetched_at": now, "error": NSNull(),
                "models": [model("gpt", "GPT", "Latest workhorse model", true)],
            ],
        ]
    }

    private func usage(now: Int64) -> [[String: Any]] {
        let second = now / 1000
        return [
            [
                "runtime": "claude", "updated_at": now, "plan": ["id": "max", "label": "Max"],
                "windows": [
                    ["name": "five_hour", "resets_at": second + 2 * 3600 + 840, "utilization": 0.18],
                    ["name": "seven_day", "resets_at": second + 4 * 86_400, "utilization": 0.41],
                ],
            ],
            [
                "runtime": "codex", "updated_at": now, "plan": ["id": "plus", "label": "Plus"],
                "windows": [
                    ["name": "five_hour", "resets_at": second + 3600, "utilization": 0.62],
                    ["name": "seven_day", "resets_at": second + 3 * 86_400, "utilization": 0.27],
                ],
            ],
        ]
    }

    private func integrations(now: Int64) -> [[String: Any]] {
        ["github", "linear", "notion", "sentry"].enumerated().map { index, name in
            [
                "id": "demo-integration-\(index)", "name": name, "kind": "http", "auth": "oauth",
                "url": "https://mcp.\(name).example/mcp", "command": NSNull(), "args": [], "env": [:], "headers": [:],
                "enabled": true, "tool_mode": "all", "tool_overrides": [:], "created_at": now - Int64(index) * 86_400_000,
            ]
        }
    }

    // MARK: files

    private func entry(_ path: String, kind: String, size: Int64, modified: Int64) -> [String: Any] {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        return [
            "name": name, "path": path, "kind": kind, "size": size, "modified_ms": modified, "hidden": name.hasPrefix("."),
            "readonly": false, "symlink_target": NSNull(), "ext": kind == "file" && !ext.isEmpty ? ext : NSNull(),
        ]
    }

    private func bigFolderEntries(now: Int64) -> [[String: Any]] {
        let extensions = ["png", "jpg", "svg", "md", "swift", "json", "txt", "pdf", "ts", "css"]
        var entries: [[String: Any]] = []
        entries.reserveCapacity(DemoDaemonFiles.bigFolderCount)
        for index in 0..<DemoDaemonFiles.bigFolderCount {
            let number = String(format: "%04d", index)
            if index < 40 {
                entries.append(
                    entry(
                        "\(DemoDaemonFiles.bigFolder)/set-\(number)", kind: "dir", size: 0,
                        modified: now - Int64(index) * 3_600_000))
            } else {
                let ext = extensions[index % extensions.count]
                let stem = ["frame", "icon", "note", "page", "report", "sketch"][index % 6]
                entries.append(
                    entry(
                        "\(DemoDaemonFiles.bigFolder)/\(stem)-\(number).\(ext)", kind: "file",
                        size: Int64(1_200 + (index * 7_919) % 4_800_000), modified: now - Int64(index) * 600_000))
            }
        }
        return entries
    }

    private func children(of path: String, now: Int64) -> [[String: Any]]? {
        switch path {
        case DemoDaemonFiles.home:
            return [
                entry("\(path)/Projects", kind: "dir", size: 0, modified: now - 60_000),
                entry("\(path)/Documents", kind: "dir", size: 0, modified: now - 86_400_000),
                entry("\(path)/Downloads", kind: "dir", size: 0, modified: now - 3_600_000),
                entry("\(path)/notes.md", kind: "file", size: 4_210, modified: now - 7_200_000),
                entry("\(path)/.zshrc", kind: "file", size: 812, modified: now - 900_000_000),
            ]
        case DemoDaemonFiles.projects:
            return ["bandito-site", "assets", "api-server", "mobile-app", "infra", "notes"].enumerated().map {
                entry("\(path)/\($1)", kind: "dir", size: 0, modified: now - Int64($0) * 86_400_000)
            }
        case DemoDaemonFiles.bigFolder:
            return bigFolderEntries(now: now)
        case "\(DemoDaemonFiles.projects)/bandito-site":
            return [
                entry("\(path)/src", kind: "dir", size: 0, modified: now - 120_000),
                entry("\(path)/README.md", kind: "file", size: 6_120, modified: now - 300_000),
                entry("\(path)/package.json", kind: "file", size: 1_410, modified: now - 400_000),
            ]
        case "\(DemoDaemonFiles.projects)/bandito-site/src":
            return [
                entry(DemoDaemonFiles.codeFile, kind: "file", size: 52_000, modified: now - 100_000),
                entry("\(path)/Router.swift", kind: "file", size: 21_000, modified: now - 200_000),
            ]
        default:
            if path.hasPrefix(DemoDaemonFiles.home) { return [] }
            return nil
        }
    }

    private func listing(_ raw: String, now: Int64) -> Result<String, RPCError> {
        let path = raw == "~" || raw.isEmpty ? DemoDaemonFiles.home : raw.replacingOccurrences(of: "~", with: DemoDaemonFiles.home)
        guard var entries = children(of: path, now: now) else {
            return .failure(
                RPCError(code: RPCError.fileError, message: "not found", data: .object(["reason": .string("not_found")])))
        }
        // The folders the app made here are listed beside the tree.
        entries += demoFolders.filter { ($0 as NSString).deletingLastPathComponent == path }
            .map { entry($0, kind: "dir", size: 0, modified: now) }
        let parent: Any = path == "/" ? NSNull() : (path as NSString).deletingLastPathComponent
        return .success(
            DemoJSON.text(["path": path, "parent": parent, "entries": entries, "truncated": false, "skipped": 0]))
    }

    private func stat(_ raw: String, now: Int64) -> Result<String, RPCError> {
        // `~` is the home folder the server's user has, as a real server answers it.
        let path = raw == "~" ? DemoDaemonFiles.home : raw
        let isDir = (path as NSString).pathExtension.isEmpty && children(of: path, now: now) != nil
        return .success(DemoJSON.text(entry(path, kind: isDir ? "dir" : "file", size: 52_000, modified: now - 100_000)))
    }

    /// Makes a folder (`fs.mkdir`), as the server does: a name that is taken answers `exists`, and the new folder is
    /// listed in its parent from then on.
    private func mkdir(_ raw: String, now: Int64) -> Result<String, RPCError> {
        let path = raw == "~" || raw.hasPrefix("~/") ? DemoDaemonFiles.home + raw.dropFirst() : raw
        let parent = (path as NSString).deletingLastPathComponent
        let inTree = children(of: parent, now: now)?.contains { ($0["path"] as? String) == path } ?? false
        guard !inTree, !demoFolders.contains(path) else {
            return .failure(RPCError(code: RPCError.fileError, message: "already exists", data: .object(["reason": .string("exists")])))
        }
        demoFolders.append(path)
        return .success(DemoJSON.text(entry(path, kind: "dir", size: 0, modified: now)))
    }

    private func read(_ path: String, now: Int64) -> Result<String, RPCError> {
        let content = DemoText.file(named: (path as NSString).lastPathComponent)
        return .success(
            DemoJSON.text([
                "path": path, "content": content, "etag": "demo-\(content.count)", "size": content.utf8.count,
                "modified_ms": now - 100_000, "readonly": false,
            ]))
    }

    private func projects(now: Int64) -> [[String: Any]] {
        ["bandito-site", "api-server", "mobile-app", "infra"].enumerated().map { index, name in
            [
                "path": "\(DemoDaemonFiles.projects)/\(name)", "name": name, "is_git": true,
                "modified_ms": now - Int64(index) * 86_400_000,
            ]
        }
    }

    // MARK: terminals

    private func terminal(_ id: String, now: Int64) -> [String: Any] {
        let size = terminalSizes[id] ?? (120, 32)
        return [
            "id": id, "title": "zsh", "cwd": "\(DemoDaemonFiles.projects)/bandito-site", "command": ["zsh"], "pid": 4300,
            "cols": size.cols, "rows": size.rows, "created_at": startedAt, "state": ["state": "running"],
            "offset": terminalOffsets[id, default: 0],
        ]
    }

    // MARK: host

    private func wave(_ now: Int64, period: Double, phase: Double = 0) -> Double {
        (sin(Double(now) / 1000 / period * 2 * .pi + phase) + 1) / 2
    }

    private func hostStats(now: Int64) -> [String: Any] {
        let gib: Int64 = 1_073_741_824
        let cpu = 18 + 34 * wave(now, period: 20)
        let names = ["claude", "node", "bandito", "codex", "chrome", "postgres", "redis", "cargo", "swift-frontend", "zsh"]
        let top: [[String: Any]] = names.enumerated().map { index, name in
            [
                "pid": 5000 + index, "name": name, "rss_bytes": Int64(900 - index * 80) * 1_048_576,
                "cpu_percent": max(0.1, cpu / Double(index + 2)), "own": index < 4, "own_safe": index < 3,
            ]
        }
        let groups: [[String: Any]] = names.prefix(6).enumerated().map { index, name in
            [
                "name": name, "cpu_percent": max(0.1, cpu / Double(index + 2)),
                "memory_bytes": Int64(1_200 - index * 150) * 1_048_576, "process_count": 1 + index % 3,
                "top": [
                    [
                        "pid": 5000 + index, "name": name, "cpu_percent": max(0.1, cpu / Double(index + 2)),
                        "memory_bytes": Int64(900 - index * 80) * 1_048_576,
                    ]
                ],
            ]
        }
        return [
            "os": "macOS 26.1", "kernel": "25.1.0", "arch": "aarch64", "hostname": setup.hostname, "cpus": 12,
            "cpu_percent": cpu, "load": [2.1 + cpu / 20, 2.4, 2.2], "mem_total": 32 * gib,
            "mem_used": Int64(Double(18 * gib) + Double(4 * gib) * wave(now, period: 30)), "swap_total": 0,
            "swap_used": 0, "disks": [["mount": "/", "total": 994 * gib, "used": 512 * gib]],
            "net_rx_bps": Int64(400_000 + 2_400_000 * wave(now, period: 12)),
            "net_tx_bps": Int64(60_000 + 300_000 * wave(now, period: 9, phase: 1)), "net_supported": true,
            "uptime_s": 431_000, "top_processes": top, "app_groups": groups,
        ]
    }

    private func hostHistory(range: String, now: Int64) -> [[String: Any]] {
        let gib: Int64 = 1_073_741_824
        let span: Int64 = range == "24h" ? 86_400_000 : 3_600_000
        let count = 360
        let step = span / Int64(count)
        return (0..<count).map { index in
            let t = now - span + Int64(index) * step
            return [
                "t": t, "cpu": 15 + 40 * wave(t, period: Double(span) / 1000 / 7),
                "mem_used": Int64(Double(16 * gib) + Double(6 * gib) * wave(t, period: Double(span) / 1000 / 3)),
                "net_rx_bps": Int64(300_000 + 2_000_000 * wave(t, period: Double(span) / 1000 / 11)),
                "net_tx_bps": Int64(50_000 + 250_000 * wave(t, period: Double(span) / 1000 / 13)),
            ]
        }
    }

    private var processes: [String: Any] {
        // Typed parts: one literal of mixed values took the CI compiler too long to type-check.
        var owners: [[String: Any]] = setup.agentIDs.prefix(12).enumerated().map { (index: Int, id: String) -> [String: Any] in
            let owner: [String: Any] = ["kind": "agent", "id": id]
            let cpu: Double = Double(index % 5) * 1.7 + 0.2
            let rss: Int64 = Int64(80 + index * 23) * 1_048_576
            let claude: [String: Any] = ["pid": 6000 + index * 3, "name": "claude", "cmd": "claude"]
            let node: [String: Any] = ["pid": 6001 + index * 3, "name": "node", "cmd": "node mcp-server.js"]
            return ["owner": owner, "cpu_percent": cpu, "rss_bytes": rss, "processes": [claude, node]]
        }
        owners.append([
            "owner": ["kind": "terminal", "id": DemoDaemonFiles.terminalID], "cpu_percent": 0.4,
            "rss_bytes": 12 * 1_048_576, "processes": [["pid": 4300, "name": "zsh", "cmd": "-zsh"]],
        ])
        owners.append([
            "owner": ["kind": "daemon", "id": NSNull()], "cpu_percent": 0.3, "rss_bytes": 22 * 1_048_576,
            "processes": [["pid": 4242, "name": "bandito", "cmd": "bandito daemon"]],
        ])
        return ["supported": true, "owners": owners]
    }

    private var ports: [String: Any] {
        let list: [(Int, String, String)] = [
            (3000, "127.0.0.1", "node"), (5173, "127.0.0.1", "vite"), (5432, "127.0.0.1", "postgres"),
            (6379, "127.0.0.1", "redis-server"), (8080, "*", "java"), (8443, "*", "nginx"), (9000, "127.0.0.1", "php-fpm"),
            (9229, "127.0.0.1", "node"), (11434, "127.0.0.1", "ollama"), (17880, "127.0.0.1", "bandito"),
            (27017, "127.0.0.1", "mongod"), (4000, "127.0.0.1", "ruby"), (8000, "127.0.0.1", "python3"),
            (1313, "127.0.0.1", "hugo"), (6006, "127.0.0.1", "node"),
        ]
        let ports: [[String: Any]] = list.enumerated().map { index, item in
            var port: [String: Any] = ["port": item.0, "addr": item.1, "pid": 7000 + index, "process": item.2]
            if index % 4 == 0, let id = setup.agentIDs.first { port["owner"] = ["kind": "agent", "id": id] }
            return port
        }
        return ["supported": true, "ports": ports]
    }

    private var workspaces: [[String: Any]] {
        [
            [
                "id": "shared", "name": "Shared", "kind": "shared", "agents": setup.agentIDs, "cpus": NSNull(),
                "memory_mb": NSNull(), "created_at": 0, "image": NSNull(), "mounts": [], "network": "internet",
                "status": NSNull(),
            ]
        ]
    }

    private func devices(now: Int64) -> [[String: Any]] {
        ["MacBook Pro", "Mac mini", "iPhone", "Studio"].enumerated().map { index, name in
            [
                "id": "demo-device-\(index)", "name": name, "current": index == 0,
                "created_at": now - Int64(index + 1) * 86_400_000 * 9, "last_seen_at": now - Int64(index) * 3_600_000,
            ]
        }
    }

    private func backups(now: Int64) -> [[String: Any]] {
        ["daily", "upgrade", "daily", "start", "manual"].enumerated().map { index, reason in
            [
                "name": "bandito-2026100\(index + 1)-040405-\(reason).db", "reason": reason,
                "size": 544_768 - index * 40_000, "created_at_ms": now - Int64(index + 1) * 86_400_000,
            ]
        }
    }

    private var serverSettings: [String: Any] {
        let values: [String: Any] = [
            "screen_idle_minutes": 30, "max_running_agents": 4, "backup_every_hours": 24, "backup_keep": 7,
            "auto_update": "notify", "update_channel": "stable", "default_approval_mode": "risky",
        ]
        return ["settings": values, "defaults": values]
    }

    private func logLines(now: Int64) -> [String] {
        (0..<300).map { index in
            let seconds = Int(now / 1000) - (300 - index) * 7
            let level = index % 17 == 0 ? "WARN" : "INFO"
            return "2026-10-12T04:\(String(format: "%02d", (seconds / 60) % 60)):\(String(format: "%02d", seconds % 60))Z \(level) bandito::rpc: request \(["agents.list", "host.stats", "fs.list", "events.page"][index % 4]) answered in \(index % 9 + 1) ms"
        }
    }

    private var setupStatus: [String: Any] {
        func component(_ feature: String, _ id: String, installed: Bool, version: Any = NSNull()) -> [String: Any] {
            [
                "feature": feature, "id": id, "installed": installed, "installable": !installed, "needs_sudo": false,
                "hint": NSNull(), "version": version,
            ]
        }
        return [
            "os": "macos", "arch": "aarch64", "package_manager": "brew", "sudo": "password",
            "components": [
                component("agents", "node", installed: true, version: "v22.20.0"),
                component("agents", "claude", installed: true, version: "2.1.300 (Claude Code)"),
                component("agents", "codex", installed: true, version: "codex-cli 0.170.0"),
                component("browser", "browser", installed: true),
                component("containers", "docker", installed: false),
            ],
            "features": [
                "agents": ["claude": "ready", "codex": "ready", "grok": "ready"], "browser": "ready",
                "containers": "missing", "screen": "unsupported",
            ],
        ]
    }
}

/// Facts of the demo daemon.
public enum DemoDaemon {
    /// The version it reports: the newest the app knows, so no update banner shows.
    public static let version = "0.1.11"

    /// What it offers: everything a daemon of this version on a Mac does (no `screen`, which needs Linux).
    public static let features = [
        "approvals", "rules", "schedules", "crew", "pairing", "usage", "memory", "history", "terminals", "files",
        "changes", "secrets", "host", "setup", "commands", "skills", "workspaces", "browser", "backups", "pause", "logs",
        "agent_own_folder", "runtime_models", "forms", "form_reply", "reactions", "attachments", "integrations",
        "template_updates", "tool_permissions", "integrations_calls", "avatar_pictures", "lead", "mentions",
        "agent_templates", "agent_bundles", "bundle_schedules", "telegram", "agent_connect", "server_settings",
    ]

    /// A server for the demo daemon: a fixed id (what the app keeps per server stays under it), a loopback address nobody listens on (never dialled: the
    /// transport is in memory), and no token.
    @MainActor public static func server(id: UUID, name: String, setup: DemoDaemonSetup) -> (ServerModel, DemoDaemonTransport) {
        let transport = DemoDaemonTransport(setup: setup)
        let config = ServerConfig(
            id: id, name: name, endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:9/demo")!), token: nil)
        let server = ServerModel(config: config, makeTransport: { _ in transport })
        return (server, transport)
    }
}

/// The catalogs the daemon ships (`daemon/src/*.json`), read once from the package's resources.
final class DemoCatalogs: Sendable {
    static let shared = DemoCatalogs()

    let integrations: String
    let skills: String
    let templates: String
    let bundles: String

    private init() {
        func load(_ name: String) -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "DemoDaemon"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { return "[]" }
            return text
        }
        integrations = load("integrations_catalog")
        templates = load("agent_templates")
        bundles = load("agent_bundles")
        // The skills catalog carries the state of each skill on the server: nothing installed here.
        let raw = load("skills_catalog")
        if let data = raw.data(using: .utf8), var list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let none: [String: Any] = ["user": false, "projects": []]
            for index in list.indices {
                list[index]["installed"] = none
                list[index]["conflicts"] = none
                list[index]["updates"] = none
            }
            skills = DemoJSON.text(list)
        } else {
            skills = "[]"
        }
    }
}

/// JSON text of plain values.
enum DemoJSON {
    static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is NSNull,
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The text of the demo files.
enum DemoText {
    static func file(named name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md":
            return (1...80).map { "## Part \($0)\n\nThe agent read the module and wrote down what it found. Nothing else changed.\n" }
                .joined(separator: "\n")
        case "json":
            return "{\n" + (1...200).map { "  \"key\($0)\": \"value \($0)\"" }.joined(separator: ",\n") + "\n}\n"
        default:
            var lines: [String] = []
            lines.reserveCapacity(1_200)
            for index in 0..<150 {
                lines.append("/// Part \(index) of the demo file: a function, its comment and a type.")
                lines.append("func step\(index)(_ items: [Item], limit: Int = \(index + 10)) -> [Item] {")
                lines.append("    let kept = items.filter { $0.weight > \(index % 7) && !$0.name.isEmpty }")
                lines.append("    return Array(kept.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))")
                lines.append("}")
                lines.append("")
                lines.append("struct Item\(index): Identifiable { let id: String; var name: String; var weight: Int }")
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }
}

/// The read end of the demo daemon's messages. The client's read loop is the only reader.
private final class DemoInbound: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<String, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> String? {
        try await iterator.next()
    }
}
