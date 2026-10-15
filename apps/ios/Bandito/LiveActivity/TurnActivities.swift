import ActivityKit
import BanditoKit
import BanditoL10n
import Foundation
import UIKit

/// The Live Activities of long turns (docs/IOS_APP.md, "A long task"). It follows the servers' live events: a turn that
/// has run for 30 seconds gets an activity (agent, what it does now, the time, Stop); it ends on "Done", "Needs you" or
/// a failure. The rules are `TurnActivityRules`; this class only applies them to ActivityKit.
///
/// One activity per (server, agent), three at most. Requests need the app in the foreground (an iOS rule), so a turn that
/// reaches 30 seconds in the background gets its activity when the app comes back (`appBecameActive`). No push: the app
/// itself updates the activity while it runs.
@MainActor
final class TurnActivities {
    static let shared = TurnActivities()

    typealias Phase = TurnActivityAttributes.Phase
    typealias State = TurnActivityAttributes.ContentState
    private typealias Rules = TurnActivityRules

    struct Key: Hashable {
        let serverID: UUID
        let agentID: String
    }

    /// One agent's activity as the app knows it.
    private final class Slot {
        let activity: Activity<TurnActivityAttributes>
        var state: State
        /// The turn the activity is for (`turnStartedAt`, Unix ms); 0 when it was found at launch.
        var turnStartedMs: Int64
        var lastDoingUpdate: Date?
        /// The activity has ended; the system keeps it on screen until its dismissal date.
        var ended = false
        /// The debug demo's activity: no event of a server touches it.
        var isDemo = false
        var trailing: Task<Void, Never>?
        var watcher: Task<Void, Never>?

        init(activity: Activity<TurnActivityAttributes>, state: State, turnStartedMs: Int64) {
            self.activity = activity
            self.state = state
            self.turnStartedMs = turnStartedMs
        }
    }

    /// The live servers. RootView sets it; the default also loads the saved ones (the Stop button can wake the app alone).
    var servers: @MainActor () -> [ServerModel] = { AppIntentHub.shared.liveServers() }
    /// The person's choice (Settings, Notifications).
    var isEnabled: @MainActor () -> Bool = { true }
    var isForeground: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }

    private var slots: [Key: Slot] = [:]
    private var timers: [Key: Task<Void, Never>] = [:]
    /// The turn (its start, Unix ms) whose activity the person swiped away: it does not come back for that turn.
    private var dismissed: [Key: Int64] = [:]
    /// Updates and ends go to ActivityKit one after the other, in the order they were made.
    private var tail: Task<Void, Never>?
    /// The servers of the last list (`serversChanged`).
    private var seenServers: Set<UUID> = []
    /// Orphans are looked for only after the servers had time to connect after the launch.
    private var sweepAllowed = false

    // MARK: Launch and settings

    /// Called once the servers are known: takes over the activities an earlier run left, and checks the running turns.
    func configure(servers: @escaping @MainActor () -> [ServerModel], isEnabled: @escaping @MainActor () -> Bool) {
        self.servers = servers
        self.isEnabled = isEnabled
        // The setting is off: nothing shows, and what an earlier run left goes.
        guard isEnabled() else {
            endAll()
            return
        }
        adoptExisting()
        appBecameActive()
        // The servers connect a moment after launch: only then is "this agent has no turn" known.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.sweepAllowed = true
            self?.sweepOrphans()
        }
    }

    /// The Settings switch changed. Off ends every activity at once.
    func settingChanged(enabled: Bool) {
        if enabled {
            appBecameActive()
        } else {
            endAll()
        }
    }

    /// The paired servers changed: the activities of a server that is gone end at once. A server this run has not seen
    /// yet is not "gone": the list is empty until the saved servers are read, and an activity of a turn that still runs
    /// must survive the launch. The sweep (`sweepOrphans`) clears the rest once the servers are known.
    func serversChanged(ids: Set<UUID>) {
        let removed = seenServers.subtracting(ids)
        seenServers = ids
        guard !removed.isEmpty else { return }
        for (key, slot) in slots where removed.contains(key.serverID) {
            endNow(key, slot)
        }
        for key in timers.keys where removed.contains(key.serverID) {
            timers[key]?.cancel()
            timers[key] = nil
        }
        // An activity the app lost track of (a second one of an agent, a server removed in an earlier run).
        for activity in Activity<TurnActivityAttributes>.activities
        where removed.contains(activity.attributes.serverID) && !slots.values.contains(where: { $0.activity.id == activity.id }) {
            removeNow(activity)
        }
    }

    /// The app came to the foreground: starts the activities of turns that passed 30 seconds meanwhile, and clears what a
    /// killed run left.
    func appBecameActive() {
        guard isEnabled() else { return }
        for server in servers() {
            for agent in server.agents {
                let key = Key(serverID: server.id, agentID: agent.id)
                let summary = server.threadSummary(for: agent.id)
                guard summary.turnRunning, let ms = summary.turnStartedAt else { continue }
                if let slot = slots[key], !slot.ended, !Rules.isFinal(slot.state.phase) {
                    refreshDoing(key)
                } else if timers[key] == nil {
                    scheduleStart(key, startedAt: Date(timeIntervalSince1970: Double(ms) / 1000))
                }
            }
        }
        sweepOrphans()
    }

    // MARK: Events

    /// One live event of a server (from `IOSNotifications.attach`).
    func ingest(_ event: Event, from server: ServerModel) {
        guard isEnabled() else { return }
        guard event.seq > 0 else { return }
        let key = Key(serverID: server.id, agentID: event.agentId)
        switch event.body {
        case .turnStarted:
            if let slot = slots[key], !slot.ended, !Rules.isFinal(slot.state.phase) { return }
            scheduleStart(key, startedAt: Date(timeIntervalSince1970: Double(event.ts) / 1000))
        case .toolCall, .toolResult:
            refreshDoing(key)
        case .turnCompleted, .approvalRequested, .approvalResolved, .approvalWithdrawn, .formRequested, .formAnswered,
            .agentStatus:
            movePhase(key, server: server, body: event.body)
        default:
            break
        }
    }

    private func movePhase(_ key: Key, server: ServerModel, body: EventBody) {
        if case .turnCompleted = body {
            // A turn that ended before its 30 seconds never gets an activity.
            timers[key]?.cancel()
            timers[key] = nil
            dismissed[key] = nil
        }
        guard let slot = slots[key], !slot.ended, !slot.isDemo else { return }
        let summary = server.threadSummary(for: key.agentID)
        let waiting = !summary.pendingApprovalRows.isEmpty || !summary.pendingForms.isEmpty
            || !summary.pendingConnects.isEmpty
        guard let phase = Rules.phase(after: body, stillWaiting: waiting) else { return }
        if case .turnCompleted = body {
            finish(slot, phase: phase)
        } else if phase != slot.state.phase {
            var next = slot.state
            next.phase = phase
            if phase == .running { next.doing = currentDoing(for: key) ?? next.doing }
            push(slot, next, stale: phase == .needsYou ? Date().addingTimeInterval(Rules.needsYouStay) : nil)
            if phase == .running { slot.lastDoingUpdate = Date() }
        }
    }

    // MARK: Starting

    private func scheduleStart(_ key: Key, startedAt: Date) {
        timers[key]?.cancel()
        let delay = Rules.delayUntilDue(startedAt: Rules.clampedStart(startedAt, now: Date()), now: Date())
        timers[key] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.timerFired(key)
        }
    }

    private func timerFired(_ key: Key) {
        timers[key] = nil
        startIfDue(key)
    }

    private func startIfDue(_ key: Key) {
        guard let server = server(key.serverID), let agent = server.agents.first(where: { $0.id == key.agentID }) else {
            return
        }
        let summary = server.threadSummary(for: key.agentID)
        guard summary.turnRunning, let ms = summary.turnStartedAt else { return }
        let now = Date()
        let startedAt = Rules.clampedStart(Date(timeIntervalSince1970: Double(ms) / 1000), now: now)
        makeRoom(for: key)
        let slot = slots[key]
        let action = Rules.startAction(
            elapsed: now.timeIntervalSince(startedAt), appActive: isForeground(), enabled: isEnabled(),
            existing: slot.map(existingPhase), running: liveCount, dismissedThisTurn: dismissed[key] == ms)
        switch action {
        case .none:
            // Not due yet (the clocks differ a little): look again when it is.
            if isEnabled(), now.timeIntervalSince(startedAt) < Rules.startAfter, slot == nil {
                scheduleStart(key, startedAt: startedAt)
            }
        case .start, .restart:
            if let slot { endNow(key, slot) }
            let waiting = !summary.pendingApprovalRows.isEmpty || !summary.pendingForms.isEmpty
                || !summary.pendingConnects.isEmpty
            let state = State(
                doing: currentDoing(for: key) ?? "", startedAt: startedAt, phase: waiting ? .needsYou : .running)
            request(key, agent: agent, state: state, turnStartedMs: ms)
        }
    }

    @discardableResult
    private func request(_ key: Key, agent: Agent, state: State, turnStartedMs: Int64) -> Slot? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let look = CrewLook(agent: agent)
        let attributes = TurnActivityAttributes(
            serverID: key.serverID, agentID: key.agentID, agentName: agent.name,
            avatarSeed: TurnAvatarSeed(color: look.color.rawValue, face: look.face.rawValue, customHex: look.customHex))
        let stale = state.phase == .needsYou ? Date().addingTimeInterval(Rules.needsYouStay) : nil
        guard let activity = try? Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: stale), pushType: nil)
        else { return nil }
        let slot = Slot(activity: activity, state: state, turnStartedMs: turnStartedMs)
        slot.lastDoingUpdate = Date()
        slots[key] = slot
        watch(key, slot)
        return slot
    }

    /// The person can swipe an activity away: that turn does not get it again.
    private func watch(_ key: Key, _ slot: Slot) {
        let activity = slot.activity
        slot.watcher = Task { [weak self, weak slot] in
            for await state in activity.activityStateUpdates {
                guard let self, let slot else { return }
                switch state {
                case .dismissed:
                    if !slot.ended && !Rules.isFinal(slot.state.phase) { self.dismissed[key] = slot.turnStartedMs }
                    self.drop(key, slot)
                    return
                case .ended:
                    slot.ended = true
                default:
                    break
                }
            }
        }
    }

    private func drop(_ key: Key, _ slot: Slot) {
        slot.trailing?.cancel()
        slot.watcher?.cancel()
        if slots[key] === slot { slots[key] = nil }
    }

    // MARK: Updating and ending

    private func currentDoing(for key: Key) -> String? {
        guard let server = server(key.serverID) else { return nil }
        return Rules.clean(AgentActivity.current(in: server.thread(for: key.agentID).items).title)
    }

    /// Shows what the agent does now, at most every 5 seconds: a change that comes sooner waits for the rest of the interval.
    private func refreshDoing(_ key: Key) {
        guard let slot = slots[key], !slot.ended, !slot.isDemo, slot.state.phase == .running,
            let doing = currentDoing(for: key)
        else { return }
        let now = Date()
        if Rules.shouldUpdateDoing(current: slot.state.doing, new: doing, lastUpdate: slot.lastDoingUpdate, now: now) {
            var next = slot.state
            next.doing = doing
            slot.lastDoingUpdate = now
            slot.trailing?.cancel()
            push(slot, next)
        } else if doing != slot.state.doing {
            let wait = Rules.doingWait(lastUpdate: slot.lastDoingUpdate, now: now)
            slot.trailing?.cancel()
            slot.trailing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refreshDoing(key)
            }
        }
    }

    private func push(_ slot: Slot, _ state: State, stale: Date? = nil) {
        slot.state = state
        let activity = slot.activity
        let content = ActivityContent(state: state, staleDate: stale)
        let handle = ActivityHandle(activity)
        enqueue { await handle.update(content) }
    }

    /// The turn is over: the activity shows the end and the system takes it off after 15 minutes (an hour for "needs you").
    private func finish(_ slot: Slot, phase: Phase) {
        guard let stay = Rules.dismissal(for: phase) else { return }
        var next = slot.state
        next.phase = phase
        slot.state = next
        slot.ended = true
        slot.trailing?.cancel()
        let activity = slot.activity
        let content = ActivityContent(state: next, staleDate: nil)
        let date = Date().addingTimeInterval(stay)
        let handle = ActivityHandle(activity)
        enqueue { await handle.end(content, dismissalPolicy: .after(date)) }
    }

    /// Takes the activity off the screen at once.
    private func endNow(_ key: Key, _ slot: Slot) {
        drop(key, slot)
        let activity = slot.activity
        removeNow(activity)
    }

    private func endAll() {
        for (key, slot) in slots { endNow(key, slot) }
        for task in timers.values { task.cancel() }
        timers.removeAll()
        for activity in Activity<TurnActivityAttributes>.activities {
            removeNow(activity)
        }
    }

    /// Ends what a killed run left: an activity whose agent has no turn any more.
    private func sweepOrphans() {
        guard sweepAllowed else { return }
        for (key, slot) in slots where !slot.ended && !slot.isDemo {
            let server = server(key.serverID)
            let orphan = Rules.isOrphan(
                phase: slot.state.phase, serverKnown: server != nil, serverConnected: server?.state == .connected,
                turnRunning: server?.threadSummary(for: key.agentID).turnRunning ?? false)
            if orphan { endNow(key, slot) }
        }
    }

    /// Takes over the activities an earlier run of the app left (they are not in `slots` after a launch). A second one of
    /// an agent is removed; one that ended is kept until the system removes it.
    private func adoptExisting() {
        for activity in Activity<TurnActivityAttributes>.activities {
            let key = Key(serverID: activity.attributes.serverID, agentID: activity.attributes.agentID)
            let phase = activity.activityState
            let kept = phase == .active || phase == .stale || phase == .ended
            guard kept, slots[key] == nil else {
                if phase != .dismissed { removeNow(activity) }
                continue
            }
            let slot = Slot(activity: activity, state: activity.content.state, turnStartedMs: 0)
            slot.ended = phase == .ended
            slots[key] = slot
            watch(key, slot)
        }
    }

    // MARK: Stop

    /// The Stop button: interrupts the turn. Without a connection the activity stays and says so; a refusal of the
    /// server says so too. A server that answers that the agent already stopped counts as done.
    func stop(serverID: String, agentID: String) async {
        guard let id = UUID(uuidString: serverID), let server = server(id) else { return }
        let key = Key(serverID: id, agentID: agentID)
        if server.state != .connected { await server.connect() }
        guard server.state == .connected else {
            showStopLine(key, L10n.Ios.Live.stopNoConnection)
            return
        }
        do {
            try await server.interrupt(agentID)
        } catch let error as RPCError where error.message.contains("stopped") {
            // The agent had already stopped: nothing is left to stop.
            return
        } catch {
            showStopLine(key, L10n.Ios.Live.stopFailed)
        }
    }

    /// Puts `text` in place of the line "what it does now". Without a slot (the app was launched by the Stop button alone)
    /// the activity itself is updated.
    private func showStopLine(_ key: Key, _ text: String) {
        if let slot = slots[key] {
            guard !slot.ended else { return }
            var next = slot.state
            next.doing = text
            // The line stays for the next interval before the agent's own text comes back.
            slot.lastDoingUpdate = Date()
            push(slot, next)
            refreshDoing(key)
            return
        }
        for activity in Activity<TurnActivityAttributes>.activities
        where activity.attributes.serverID == key.serverID && activity.attributes.agentID == key.agentID
            && (activity.activityState == .active || activity.activityState == .stale)
        {
            var next = activity.content.state
            next.doing = text
            let content = ActivityContent(state: next, staleDate: activity.content.staleDate)
            let handle = ActivityHandle(activity)
            enqueue { await handle.update(content) }
        }
    }

    // MARK: Helpers

    private func server(_ id: UUID) -> ServerModel? {
        servers().first { $0.id == id }
    }

    /// The phase the rules see for a slot (`TurnActivityRules.effectivePhase`).
    private func existingPhase(_ slot: Slot) -> Phase {
        Rules.effectivePhase(shown: slot.state.phase, ended: slot.ended)
    }

    /// At the limit, the oldest ended activity of another agent leaves the screen at once: a finished card must not keep a
    /// running turn off the lock screen for its 15 minutes (or an hour).
    private func makeRoom(for key: Key) {
        guard liveCount >= Rules.maxRunning else { return }
        let oldest = slots
            .filter { $0.key != key && $0.value.ended && !$0.value.isDemo }
            .min { $0.value.turnStartedMs < $1.value.turnStartedMs }
        guard let (oldKey, oldSlot) = oldest else { return }
        oldSlot.trailing?.cancel()
        oldSlot.watcher?.cancel()
        slots[oldKey] = nil
        removeNow(oldSlot.activity)
    }

    /// The activities on screen: running, waiting for the person, and ended ones the system has not removed yet.
    private var liveCount: Int {
        slots.count
    }

    private func removeNow(_ activity: Activity<TurnActivityAttributes>) {
        let handle = ActivityHandle(activity)
        enqueue { await handle.end(nil, dismissalPolicy: .immediate) }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    // MARK: Debug demo

    #if DEBUG
    static let demoArgument = "-live-demo"

    /// `-live-demo` (with `-demo`): an activity for Forge, "Running tests", that turns into "Done" after 20 seconds
    /// (`-live-demo-seconds N` changes the time, for pictures that need longer).
    func runDemo(servers: [ServerModel], arguments: [String]) {
        let seconds = arguments.firstIndex(of: "-live-demo-seconds")
            .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 20
        guard let server = servers.first, let agent = server.agents.first(where: { $0.name == "Forge" }) else { return }
        let key = Key(serverID: server.id, agentID: agent.id)
        if let old = slots[key] { endNow(key, old) }
        let state = State(doing: "Running tests", startedAt: Date(), phase: .running)
        guard let slot = request(key, agent: agent, state: state, turnStartedMs: 0) else { return }
        slot.isDemo = true
        Task { [weak self, weak slot] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let slot, !slot.ended else { return }
            self.finish(slot, phase: .done)
        }
    }
    #endif
}

/// ActivityKit's `Activity` is not `Sendable`, but its calls are safe from any task. The queue of updates holds this.
private struct ActivityHandle: @unchecked Sendable {
    let activity: Activity<TurnActivityAttributes>

    init(_ activity: Activity<TurnActivityAttributes>) {
        self.activity = activity
    }

    func update(_ content: ActivityContent<TurnActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<TurnActivityAttributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
}
