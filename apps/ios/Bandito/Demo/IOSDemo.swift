import BanditoKit
import BanditoL10n
import Foundation

/// The demo world of the `-demo` launch argument: BanditoKit's demo daemons, with a small team on the first and an empty
/// second server, so the core can be checked on the simulator without a server. `-demo-empty` shows the first server
/// without any agent. Nothing leaves the process.
@MainActor
enum IOSDemo {
    static let launchArgument = "-demo"
    static let emptyArgument = "-demo-empty"
    static let serverID = UUID(uuidString: "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B")!
    /// The scripted replies of the demo server (the tests set their pace).
    static var scripts: [UUID: DemoChatScript] = [:]
    static let officeServerID = UUID(uuidString: "2A7D9E40-5B1C-4F8E-8C33-7E0A1B2C3D4E")!

    /// One message of a demo agent's history: the person's (or the agent's), how long ago it was.
    struct Turn: Sendable {
        let fromPerson: Bool
        let text: String
        let minutesAgo: Int64
        /// A scheduled run: `text` is its prompt, and the agent's next message is what it said.
        var schedule: String?
        /// An error the agent reported (the text is the message).
        var isError = false
    }

    struct Member: Sendable {
        let name: String
        let role: String
        let runtime: RuntimeKind
        let status: AgentStatus
        var lead = false
        /// The history the agent starts with, oldest first. The newest agent message is its last line.
        var history: [Turn] = []
    }

    static let team: [Member] = [
        Member(
            name: "Forge", role: "Builder", runtime: .claude, status: .working, lead: true,
            history: [
                Turn(fromPerson: true, text: "Look at the build and push the branch.", minutesAgo: 9),
                Turn(fromPerson: false, text: "Build is green. Pushing feat/ios-crew next.", minutesAgo: 4),
            ]),
        Member(
            name: "Scout", role: "Researcher", runtime: .codex, status: .idle,
            history: [
                Turn(fromPerson: true, text: "What do the sources say about the release?", minutesAgo: 75),
                Turn(fromPerson: false, text: "Two of the three sources agree on the date.", minutesAgo: 70),
            ]),
        Member(
            name: "Watch", role: "On call", runtime: .grok, status: .needsYou,
            history: [
                Turn(
                    fromPerson: false, text: "Check the disk and tell me only when it is above 80%.", minutesAgo: 52,
                    schedule: "Nightly disk check"),
                Turn(fromPerson: false, text: "The server disk is 81% full. Should I clear the cache?", minutesAgo: 38),
            ]),
        Member(
            name: "Quill", role: "Docs", runtime: .claude, status: .error,
            history: [
                Turn(fromPerson: false, text: "Changelog build: a release has no date.", minutesAgo: 27 * 60, isError: true),
                Turn(fromPerson: false, text: "The changelog build failed on a missing date.", minutesAgo: 26 * 60),
            ]),
    ]

    /// The reply Scout writes after the first look: it arrives unread, so Scout shows the unread badge.
    static let unreadReply = "I can summarize the third source too."

    /// Whether the launch arguments ask for the demo world.
    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains(launchArgument) || arguments.contains(emptyArgument)
    }

    /// Whether the launch arguments ask for the demo world with no agent on its first server.
    static func isEmptyRequested(in arguments: [String]) -> Bool {
        arguments.contains(emptyArgument)
    }

    /// The demo servers, connected: the team's (or none) and an office server with no agent, so the server switcher
    /// has something to switch to.
    static func startServers(withTeam: Bool = true) async -> [ServerModel] {
        let main = await start(withTeam: withTeam)
        let office = await startOffice()
        return [main, office]
    }

    /// Makes the demo server, connects it, and installs the team with its history. The team goes in after the connect:
    /// the connect reads the agents of the daemon, which has none of its own. Forge asks for an approval, so the Crew
    /// shows a card; Scout gets one reply after the first look, so it shows an unread badge.
    static func start(withTeam: Bool = true) async -> ServerModel {
        await startWithTransport(withTeam: withTeam).0
    }

    /// The demo server with the daemon behind it: the tests answer their own requests through the transport.
    static func startWithTransport(withTeam: Bool = true) async -> (ServerModel, DemoDaemonTransport) {
        let members = withTeam ? team : []
        let ids = members.indices.map { "ios-demo-\($0 + 1)" }
        let (server, transport) = DemoDaemon.server(
            id: serverID, name: "Demo", setup: DemoDaemonSetup(agentIDs: ids, hostname: "demo"))
        await server.connect()
        // The agents answer a message (a streamed reply, an approval); the tests set their own pace.
        let script = DemoChatScript(transport: transport)
        await transport.setClientHook { call in script.handle(call) }
        scripts[serverID] = script
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, member) in members.enumerated() {
            var agent = Agent(
                id: ids[index], name: member.name, role: member.role, runtime: member.runtime,
                cwd: DemoDaemonFiles.projects, createdAt: now, updatedAt: now, status: member.status)
            agent.lead = member.lead
            // Message n has seq n: the reply ids (`s<seq>`) are what counts a chat's unread replies.
            let recent: [ThreadItem] = member.history.enumerated().map { offset, turn -> ThreadItem in
                let ts = now - turn.minutesAgo * 60_000
                let id = "s\(offset + 1)"
                if let schedule = turn.schedule {
                    let run = ScheduleRun(id: "ios-demo-run-\(offset + 1)", name: schedule, firedAt: ts)
                    return .scheduleRun(id: id, run: run, prompt: turn.text, ts: ts)
                }
                if turn.isError {
                    return .note(id: id, text: turn.text, kind: .error, ts: ts)
                }
                return turn.fromPerson
                    ? .user(id: id, text: turn.text, source: .user, from: nil, ts: ts)
                    : .assistant(id: id, text: turn.text, ts: ts)
            }
            let items = (member.lead ? forgeBackstory(now: now) : []) + recent
            server.installSyntheticAgent(agent, items: items)
            // The daemon knows the agent too, so that editing and deleting it answer as a real server does.
            await transport.remember(agent)
            if member.name == "Watch" {
                await transport.rememberSchedule(
                    id: "ios-demo-schedule-1", agentID: ids[index], cron: "0 22 * * *", tz: "Asia/Vladivostok",
                    prompt: L10n.Ios.Demo.Schedule.nightly, title: nil, enabled: true)
                await transport.rememberSchedule(
                    id: "ios-demo-schedule-2", agentID: ids[index], cron: "0 9 * * 1", tz: "Asia/Vladivostok",
                    prompt: L10n.Ios.Demo.Schedule.weekly, title: nil, enabled: false)
            }
        }
        // What the team has read so far: every chat is read to its last message.
        for id in ids {
            server.threadSummary(for: id).markRead()
        }
        // What waits for the person, one of each kind the Inbox lists. Each request is linked to its agent, so the demo
        // daemon names the agent when the person answers it (the answer then leaves the Inbox).
        func agent(named name: String) -> String? {
            zip(members, ids).first { $0.0.name == name }?.1
        }
        func deliver(_ body: EventBody, to agentID: String) {
            server.apply(Event(seq: server.thread(for: agentID).lastSeq + 1, agentId: agentID, ts: now, body: body))
        }
        if let forge = agent(named: "Forge") {
            // A risky approval (the push), and an ordinary one (the tests), both of Forge.
            deliver(
                .approvalRequested(
                    approvalId: "ios-demo-approval-1", callId: "ios-demo-call-1", tool: "bash",
                    title: "git push origin feat/ios-crew", command: "git push origin feat/ios-crew", diff: nil,
                    reason: "risky: git push"),
                to: forge)
            deliver(
                .approvalRequested(
                    approvalId: "ios-demo-approval-2", callId: "ios-demo-call-2", tool: "bash",
                    title: "swift test -q", command: "swift test -q", diff: nil,
                    reason: "approval required for every action"),
                to: forge)
            await transport.link("ios-demo-approval-1", toAgent: forge)
            await transport.link("ios-demo-approval-2", toAgent: forge)
        }
        if let quill = agent(named: "Quill") {
            let form = FormSpec(
                title: "Changelog date", intro: "Which day goes on the changelog?", kind: .question,
                fields: [
                    FormField(id: "day", label: "Release day", type: .date, isRequired: true, placeholder: "2026-10-13"),
                    FormField(
                        id: "channel", label: "Channel", type: .choice, options: ["stable", "beta"],
                        defaultValue: .string("stable")),
                    FormField(id: "notes", label: "Mention in the notes", type: .boolean, defaultValue: .bool(true)),
                ],
                submitLabel: "Send", rejectLabel: "Not now")
            deliver(.formRequested(formId: "ios-demo-form-1", spec: form), to: quill)
            await transport.link("ios-demo-form-1", toAgent: quill)
        }
        if let watch = agent(named: "Watch") {
            // A question with the buttons the agent offers under it.
            deliver(
                .agentQuickReplies(
                    buttons: [
                        QuickReplyButton(label: "Clear the cache", reply: "Yes, clear the cache."),
                        QuickReplyButton(label: "Not now", reply: "Not now, leave it."),
                    ],
                    link: nil, progress: nil),
                to: watch)
        }
        if let scout = agent(named: "Scout") {
            deliver(.messageAssistant(text: unreadReply), to: scout)
        }
        return (server, transport)
    }

    /// What Forge said and did before the first look: an earlier task with seven commands and a reply with a list and a
    /// code block, so the chat opens on something to read. Ids do not look like events (no unread count comes from them).
    static func forgeBackstory(now: Int64) -> [ThreadItem] {
        let day: Int64 = 24 * 3_600_000
        let base = now - day - 40 * 60_000
        let commands = [
            "git status --short", "swift build -q", "swift test -q --filter SendQueue", "rg \"retry\" Sources", "git diff --stat",
            "swiftformat --lint Sources", "git log --oneline -5",
        ]
        var items: [ThreadItem] = [
            .user(id: "demo-b1", text: "Add a retry to the send queue and run the tests.", source: .user, from: nil, ts: base)
        ]
        for (index, command) in commands.enumerated() {
            items.append(
                .tool(ToolRow(callId: "demo-b-call-\(index)", tool: "bash", title: command, ok: true, output: "ok", startedAt: base + Int64(index) * 4_000)))
        }
        items.append(
            .assistant(
                id: "demo-b2",
                text: """
                    The queue now **resends** a message that dropped midway.

                    ## What changed
                    - `SendQueue.swift` keeps the message until the server answers
                    - the order of the messages never changes
                    - 12 tests cover it

                    ```swift
                    func retry(_ id: String) {
                        queue.retry(id)
                        pump()
                    }
                    ```

                    Notes are in the [design doc](https://bandito.dev/docs).
                    """,
                ts: base + 60_000))
        return items
    }

    /// A second demo server with no agent, connected.
    static func startOffice() async -> ServerModel {
        let (server, _) = DemoDaemon.server(
            id: officeServerID, name: "Office", setup: DemoDaemonSetup(agentIDs: [], hostname: "office"))
        await server.connect()
        return server
    }
}
