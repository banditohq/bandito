#if os(macOS)
import AppKit
import BanditoKit
import BanditoL10n
import CoreGraphics
import Foundation
import QuartzCore

// The pages the smoothness check drives, one scenario each. A scenario does what a person would do on the page
// (scroll, open and close, switch, type) through the router and the scroll views of the demo window, one step a
// frame, while `FrameRecorder` counts the frames. No system mouse or keyboard events are made.

/// The scenarios, by the word of the QA command `perf <scenario>`.
enum PerfScenario: String, CaseIterable, Sendable {
    case team, thread, threadfast, typing, stream, inspector, newagent
    case `switch`, files, terminals, browser, screen, server, market, settings, modes, overlays

    /// The page's name in the results.
    var title: String {
        switch self {
        case .team: L10n.PerfCheck.Page.team
        case .thread: L10n.PerfCheck.Page.thread
        case .threadfast: L10n.PerfCheck.Page.threadFast
        case .typing: L10n.PerfCheck.Page.typing
        case .stream: L10n.PerfCheck.Page.stream
        case .inspector: L10n.PerfCheck.Page.inspector
        case .newagent: L10n.PerfCheck.Page.newAgent
        case .switch: L10n.PerfCheck.Page.switchAgents
        case .files: L10n.PerfCheck.Page.files
        case .terminals: L10n.PerfCheck.Page.terminals
        case .browser: L10n.PerfCheck.Page.browser
        case .screen: L10n.PerfCheck.Page.screen
        case .server: L10n.PerfCheck.Page.server
        case .market: L10n.PerfCheck.Page.market
        case .settings: L10n.PerfCheck.Page.settings
        case .modes: L10n.PerfCheck.Page.modes
        case .overlays: L10n.PerfCheck.Page.overlays
        }
    }
}

/// Where a scenario runs: the demo window and its models.
@MainActor
struct PerfStage {
    let window: NSWindow
    let world: PerfDemoWorld
    let recorder: FrameRecorder
    /// Shows the Settings pages in the window instead of the app (true) or the app again (false).
    let showSettings: (Bool) -> Void

    var router: Router { world.router }
    var app: AppModel { world.app }
    var server: ServerModel { world.primary }
}

@MainActor
enum PerfScenarios {
    /// Runs one scenario on the stage and makes its report.
    static func run(_ scenario: PerfScenario, on stage: PerfStage) async -> PerfReport {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let recorder = stage.recorder
        let tally = HangTally()
        HangMonitor.observeHangs { length in tally.add(length) }
        defer { HangMonitor.observeHangs(nil) }
        PerfTrace.write("\(scenario.rawValue): start")
        let steps = PerfSteps(stage: stage)
        await steps.reset()
        let memoryStart = physicalFootprintBytes()
        let began = CACurrentMediaTime()
        var note = ""
        var error: String?
        do {
            note = try await steps.run(scenario)
        } catch let problem as PerfProblem {
            error = problem.message
        } catch {
            // Cancellation (the window was closed) is the only other failure.
        }
        let stats = recorder.recording ? recorder.finish() : FrameStats.compute(intervals: [], frameDuration: 0)
        let duration = CACurrentMediaTime() - began
        let memoryEnd = physicalFootprintBytes()
        PerfTrace.write("\(scenario.rawValue): done")
        let fps = stage.window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        let meets = error == nil && stats.meetsTarget(displayFrameMs: recorder.displayFrameMs)
        return PerfReport(
            scenario: scenario.rawValue, startedAt: startedAt, durationSec: (duration * 100).rounded() / 100,
            frames: stats, hangs: tally.count, longestHangMs: (Double(tally.longest) / 10_000).rounded() / 100,
            memoryStartMB: mb(memoryStart), memoryPeakMB: mb(max(recorder.peakFootprint, memoryEnd)),
            memoryEndMB: mb(memoryEnd), segments: recorder.segments, silentFrames: recorder.silentFrames,
            bodies: PerfCounters.snapshot(), note: note, error: error, screenFPS: fps, meetsTarget: meets)
    }

    private static func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
}

/// The steps of the scenarios. Every step waits for a frame, so the counts are the frames of the real interface.
@MainActor
private struct PerfSteps {
    let stage: PerfStage

    private var router: Router { stage.router }
    private var server: ServerModel { stage.server }
    private var window: NSWindow { stage.window }
    private var recorder: FrameRecorder { stage.recorder }
    private var world: PerfDemoWorld { stage.world }

    private func settle(_ frames: Int = 40) async { await recorder.frames(frames) }

    private func check() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    /// The window as a scenario finds it: the team mode, nothing open, the first server in front.
    func reset() async {
        stage.showSettings(false)
        router.sheet = nil
        router.paletteOpen = false
        router.usagePopoverOpen = false
        router.botNotice = nil
        router.files.showsViewer = false
        world.requests.filesLayout = .list
        world.requests.overviewMetric = nil
        if world.app.selectedServerID != world.primary.id { world.app.selectedServerID = world.primary.id }
        router.closeWorkbenchPanel(agentID: PerfFixtures.threadAgentID)
        router.select(mode: .team)
        router.selectedAgentID = world.agentIDs.first
        await settle(20)
    }

    func run(_ scenario: PerfScenario) async throws -> String {
        switch scenario {
        case .team: try await team()
        case .thread: try await thread()
        case .threadfast: try await threadFast()
        case .typing: try await typing()
        case .stream: try await stream()
        case .inspector: try await inspector()
        case .newagent: try await newAgent()
        case .switch: try await switchAgents()
        case .files: try await files()
        case .terminals: try await terminals()
        case .browser: try await browser()
        case .screen: try await screen()
        case .server: try await serverPages()
        case .market: try await market()
        case .settings: try await settings()
        case .modes: try await modes()
        case .overlays: try await overlays()
        }
    }

    // MARK: scrolling

    /// Scrolls from the current place towards the top or the bottom at `speed` points a frame (`perFrame` wheel
    /// events in each). Stops at the end, after `limit` frames or after `seconds`.
    @discardableResult
    private func sweep(
        _ scroll: NSScrollView, toTop: Bool, speed: CGFloat, perFrame: Int = 1, limit: Int = 4_000,
        seconds: Double = 6
    ) async throws -> Int {
        var steps = 0
        var quiet = 0
        let deadline = CACurrentMediaTime() + seconds
        while steps < limit, CACurrentMediaTime() < deadline {
            try check()
            await recorder.nextFrame()
            steps += 1
            for _ in 0..<perFrame {
                let y = PerfScroller.offset(scroll)
                if toTop {
                    if y <= 1 {
                        // At the top: older rows may still be added; wait a little for the content to grow.
                        quiet += 1
                        break
                    }
                    quiet = 0
                    PerfScroller.scroll(scroll, to: y - speed)
                } else {
                    if y >= PerfScroller.maxOffset(scroll) - 1 { return steps }
                    PerfScroller.scroll(scroll, to: y + speed)
                }
            }
            if quiet > 20 { break }
        }
        PerfTrace.write("sweep \(toTop ? "up" : "down") ended after \(steps) steps")
        return steps
    }

    /// Scrolls the main scroll view of the window down and back up, when it has one.
    private func sweepMain(speed: CGFloat = 50, seconds: Double = 4) async throws {
        guard let scroll = PerfScroller.main(in: window) else {
            await settle(20)
            return
        }
        try await sweep(scroll, toTop: false, speed: speed, seconds: seconds)
        try await sweep(scroll, toTop: true, speed: speed, seconds: seconds)
    }

    /// Waits (up to `frames`) until `ready` holds.
    private func wait(frames: Int = 300, until ready: () -> Bool) async throws {
        for _ in 0..<frames where !ready() {
            try check()
            await recorder.nextFrame()
        }
    }

    // MARK: team

    private func openThread() async throws {
        router.select(mode: .team)
        router.selectedAgentID = PerfFixtures.threadAgentID
        await settle(60)
    }

    func team() async throws -> String {
        router.select(mode: .team)
        router.showTeamHome()
        await settle(40)
        recorder.begin()
        recorder.beginSegment()
        try await sweepMain(speed: 40)
        recorder.endSegment("home")
        recorder.beginSegment()
        let sidebarPoint = NSPoint(x: 150, y: window.contentLayoutRect.height * 0.45)
        if let sidebar = PerfScroller.at(sidebarPoint, in: window) {
            try await sweep(sidebar, toTop: false, speed: 30, seconds: 4)
            try await sweep(sidebar, toTop: true, speed: 30, seconds: 4)
        } else {
            await settle(30)
        }
        recorder.endSegment("sidebar")
        recorder.beginSegment()
        for _ in 0..<4 {
            try check()
            router.leaveTeamHome()
            await settle(24)
            router.showTeamHome()
            await settle(24)
        }
        recorder.endSegment("open and close")
        return "\(world.agentIDs.count) agents: the team home scrolled, the sidebar scrolled, the home left and shown 4 times"
    }

    func thread() async throws -> String {
        try await openThread()
        guard let scroll = PerfScroller.main(in: window) else { throw PerfProblem(message: "no scroll view to drive") }
        recorder.begin()
        recorder.beginSegment()
        try await sweep(scroll, toTop: true, speed: 100, seconds: 8)
        recorder.endSegment("up")
        recorder.beginSegment()
        try await sweep(scroll, toTop: false, speed: 100, seconds: 8)
        recorder.endSegment("down")
        await settle(20)
        return "\(PerfDemoWorld.threadRows) rows: from the newest message towards the oldest and back, 100 pt a frame, 8 s at most each way"
    }

    func threadFast() async throws -> String {
        try await openThread()
        guard let scroll = PerfScroller.main(in: window) else { throw PerfProblem(message: "no scroll view to drive") }
        recorder.begin()
        for _ in 0..<2 {
            try await sweep(scroll, toTop: true, speed: 60, perFrame: 4, seconds: 4)
            try await sweep(scroll, toTop: false, speed: 60, perFrame: 4, seconds: 4)
        }
        await settle(20)
        return "\(PerfDemoWorld.threadRows) rows, 2 round trips, 4 scroll events of 60 pt in every frame (a hard flick of a trackpad), 4 s at most each way"
    }

    func typing() async throws -> String {
        try await openThread()
        let id = PerfFixtures.threadAgentID
        router.requestComposerFocus(agentID: id)
        await settle(30)
        guard let editor = window.firstResponder as? NSTextView else {
            throw PerfProblem(message: "the composer did not take focus")
        }
        let words = "the quick brown fox jumps over the lazy dog while the agent reads every file in the folder "
        let text = Array(String(String(repeating: words, count: 3).prefix(200)))
        recorder.begin()
        for character in text {
            try check()
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await recorder.nextFrame()
        }
        await settle(20)
        // Leave the draft empty.
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        return "\(PerfDemoWorld.threadRows) rows, 200 characters typed into the composer, one a frame"
    }

    /// An agent writes a long reply, a few words a frame (the daemon's `message.delta`), while its chat is on screen;
    /// then another agent writes one while the first chat stays on screen.
    func stream() async throws -> String {
        try await openThread()
        let transport = world.primaryTransport
        let words = "the agent reads the module and the three call sites and writes down what it found and why ".split(
            separator: " ")
        func write(_ agentID: String, frames: Int) async throws {
            let turn = "demo-turn-\(agentID)-\(frames)"
            await transport.emitEvent(
                agentID: agentID, kind: "turn.started", payload: ["turn_id": turn, "source": "user"], persisted: true)
            var text = ""
            for index in 0..<frames {
                try check()
                let chunk = (0..<3).map { String(words[(index * 3 + $0) % words.count]) }.joined(separator: " ") + " "
                text += chunk
                if index % 40 == 39 { text += "\n\n" }
                await transport.emitEvent(agentID: agentID, kind: "message.delta", payload: ["text": chunk], persisted: false)
                await recorder.nextFrame()
            }
            await transport.emitEvent(agentID: agentID, kind: "message.assistant", payload: ["text": text], persisted: true)
            await transport.emitEvent(
                agentID: agentID, kind: "turn.completed", payload: ["turn_id": turn, "status": "ok"], persisted: true)
            await settle(30)
        }
        recorder.begin()
        recorder.beginSegment()
        try await write(PerfFixtures.threadAgentID, frames: 240)
        recorder.endSegment("shown agent")
        recorder.beginSegment()
        try await write(world.agentIDs[3], frames: 240)
        recorder.endSegment("other agent")
        return "a reply streamed three words a frame for 4 s into the chat on screen, then into another agent's chat"
    }

    func inspector() async throws -> String {
        try await openThread()
        let id = PerfFixtures.threadAgentID
        recorder.begin()
        recorder.beginSegment()
        for _ in 0..<4 {
            try check()
            router.inspectorTab = .details
            router.showInWorkbench(.details, agentID: id)
            await settle(30)
            router.toggleWorkbench()
            await settle(24)
        }
        recorder.endSegment("open and close")
        router.inspectorTab = .details
        router.showInWorkbench(.details, agentID: id)
        await settle(30)
        recorder.beginSegment()
        for _ in 0..<3 {
            for tab in InspectorTab.allCases {
                try check()
                router.inspectorTab = tab
                await settle(24)
            }
        }
        recorder.endSegment("tabs")
        router.toggleWorkbench()
        await settle(20)
        return "the agent's panel opened and closed 4 times, then its tabs (details, memory, where it runs) 3 times over"
    }

    func newAgent() async throws -> String {
        recorder.begin()
        for _ in 0..<3 {
            try check()
            router.sheet = .newAgent
            await settle(40)
            if let scroll = PerfScroller.main(in: window), scroll.documentView?.frame.height ?? 0 < 20_000 {
                try await sweep(scroll, toTop: false, speed: 30, seconds: 2)
                try await sweep(scroll, toTop: true, speed: 30, seconds: 2)
            }
            router.sheet = nil
            await settle(30)
        }
        return "the New agent sheet opened, scrolled and closed 3 times"
    }

    func switchAgents() async throws -> String {
        router.select(mode: .team)
        await settle(30)
        let ids = Array(world.agentIDs.prefix(20))
        recorder.begin()
        recorder.beginSegment()
        for id in ids {
            try check()
            router.selectedAgentID = id
            await settle(12)
        }
        recorder.endSegment("agents")
        recorder.beginSegment()
        for mode in AppMode.allCases {
            try check()
            router.select(mode: mode)
            await settle(30)
        }
        router.select(mode: .team)
        await settle(20)
        recorder.endSegment("modes")
        return "\(ids.count) agents of \(PerfDemoWorld.agentRows) rows switched one after the other, then every mode"
    }

    // MARK: files, terminals, browser, screen

    func files() async throws -> String {
        router.select(mode: .files)
        router.openInFiles(DemoDaemonFiles.bigFolder, isFile: false)
        await settle(30)
        try await wait { PerfScroller.main(in: window).map { PerfScroller.maxOffset($0) > 20_000 } ?? false }
        await settle(20)
        recorder.begin()
        recorder.beginSegment()
        if let list = PerfScroller.main(in: window) {
            try await sweep(list, toTop: false, speed: 80, seconds: 5)
            try await sweep(list, toTop: true, speed: 80, seconds: 5)
        }
        recorder.endSegment("list")
        world.requests.filesLayout = .grid
        await settle(30)
        recorder.beginSegment()
        if let grid = PerfScroller.main(in: window) {
            try await sweep(grid, toTop: false, speed: 80, seconds: 5)
            try await sweep(grid, toTop: true, speed: 80, seconds: 5)
        }
        recorder.endSegment("grid")
        world.requests.filesLayout = .list
        await settle(20)
        recorder.beginSegment()
        router.openInFiles(DemoDaemonFiles.codeFile, isFile: true)
        await settle(60)
        if let viewer = PerfScroller.main(in: window) {
            try await sweep(viewer, toTop: false, speed: 60, seconds: 4)
            try await sweep(viewer, toTop: true, speed: 60, seconds: 4)
        }
        router.files.showsViewer = false
        await settle(30)
        recorder.endSegment("viewer")
        return "a folder of \(DemoDaemonFiles.bigFolderCount) entries scrolled as a list and as icons, then a file of 1 200 lines opened and scrolled"
    }

    func terminals() async throws -> String {
        router.select(mode: .terminals)
        await settle(90)
        recorder.begin()
        recorder.beginSegment()
        var written = 0
        while written < 10_000 {
            try check()
            await world.primaryTransport.emitTerminalOutput(lines: 200)
            written += 200
            await recorder.nextFrame()
        }
        await settle(60)
        recorder.endSegment("output")
        return "10 000 lines of output, 200 in every frame"
    }

    func browser() async throws -> String {
        world.showDemoBrowser()
        router.select(mode: .browser)
        await settle(40)
        let model = BrowserStore.shared.model(for: server)
        let tabs = model.tabs
        recorder.begin()
        for _ in 0..<3 {
            for tab in tabs {
                try check()
                await model.selectPage(tab.id)
                await settle(14)
            }
        }
        return "\(tabs.count) tabs of the browser switched 3 times over"
    }

    func screen() async throws -> String {
        router.select(mode: .screen)
        await settle(30)
        recorder.begin()
        await settle(90)
        try await sweepMain()
        return "the Screen page of a server without a screen, shown for a second and a half, scrolled when it can be"
    }

    // MARK: server, market, settings

    func serverPages() async throws -> String {
        router.select(mode: .server)
        recorder.begin()
        for section in ServerSection.allCases {
            try check()
            router.serverSection = section
            recorder.beginSegment()
            await settle(36)
            try await sweepMain(seconds: 3)
            recorder.endSegment(section.rawValue)
        }
        router.serverSection = .overview
        await settle(40)
        recorder.beginSegment()
        for metric in OverviewMetric.allCases {
            try check()
            world.requests.overviewMetric = metric
            await settle(40)
            world.requests.overviewMetric = nil
            await settle(20)
        }
        recorder.endSegment("graphs")
        return "every section of the Server page opened and scrolled, then the graph of each metric opened and closed"
    }

    func market() async throws -> String {
        router.select(mode: .market)
        router.marketTab = .services
        try await wait(frames: 600) { !router.marketCategories.isEmpty }
        await settle(30)
        recorder.begin()
        recorder.beginSegment()
        try await sweepMain(speed: 50, seconds: 5)
        recorder.endSegment("services")
        recorder.beginSegment()
        for name in router.marketCategories {
            try check()
            router.requestMarketScroll(.category(name))
            await settle(30)
        }
        router.requestMarketScroll(.top)
        await settle(30)
        recorder.endSegment("category jumps")
        recorder.beginSegment()
        for id in ["github", "notion", "linear"] {
            try check()
            router.marketDetail = id
            await settle(40)
            router.marketDetail = nil
            await settle(24)
        }
        recorder.endSegment("cards")
        for tab in [MarketTab.bots, .skills] {
            try check()
            router.marketTab = tab
            recorder.beginSegment()
            await settle(40)
            try await sweepMain(speed: 50, seconds: 4)
            recorder.endSegment(tab.rawValue)
        }
        router.marketTab = .services
        await settle(20)
        return "Services scrolled down and up, every category jumped to, 3 cards opened, then Bots and Skills scrolled"
    }

    func settings() async throws -> String {
        stage.showSettings(true)
        await settle(40)
        recorder.begin()
        for section in SettingsSection.allCases {
            try check()
            world.settingsNavigation.requested = section
            recorder.beginSegment()
            await settle(24)
            try await sweepMain(seconds: 2.5)
            recorder.endSegment(section.rawValue)
        }
        recorder.beginSegment()
        world.settingsNavigation.requestedServer = server.id
        world.settingsNavigation.requested = .servers
        await settle(40)
        try await sweepMain(seconds: 3)
        recorder.endSegment("server page")
        stage.showSettings(false)
        await settle(30)
        return "every section of Settings opened and scrolled, then the settings page of a server"
    }

    // MARK: moving around

    func modes() async throws -> String {
        recorder.begin()
        for round in 0..<2 {
            for mode in AppMode.allCases {
                try check()
                recorder.beginSegment()
                router.select(mode: mode)
                await settle(30)
                recorder.endSegment(round == 0 ? "open \(mode.rawValue)" : "again \(mode.rawValue)")
            }
        }
        recorder.beginSegment()
        for mode in [AppMode.team, .files, .server] {
            router.select(mode: mode)
            await settle(24)
            for _ in 0..<2 {
                try check()
                world.app.selectedServerID = world.secondary.id
                await settle(36)
                world.app.selectedServerID = world.primary.id
                await settle(36)
            }
        }
        recorder.endSegment("servers")
        return "every mode twice, then the two servers switched in Team, Files and Server"
    }

    func overlays() async throws -> String {
        router.select(mode: .team)
        router.selectedAgentID = world.agentIDs.first
        await settle(30)
        recorder.begin()
        recorder.beginSegment()
        for _ in 0..<3 {
            try check()
            router.paletteOpen = true
            await settle(30)
            router.paletteOpen = false
            await settle(20)
        }
        recorder.endSegment("palette")
        recorder.beginSegment()
        for _ in 0..<3 {
            try check()
            router.usagePopoverOpen = true
            await settle(30)
            router.usagePopoverOpen = false
            await settle(20)
        }
        recorder.endSegment("usage")
        recorder.beginSegment()
        if let agentID = world.agentIDs.first {
            for _ in 0..<2 {
                try check()
                router.sheet = .schedule(agentID: agentID, existing: nil)
                await settle(36)
                router.sheet = nil
                await settle(24)
            }
        }
        recorder.endSegment("sheets")
        recorder.beginSegment()
        for index in 0..<3 {
            try check()
            router.botNotice = BotNotice(agentName: PerfFixtures.names[index], problems: [])
            await settle(36)
            router.botNotice = nil
            await settle(24)
        }
        recorder.endSegment("toasts")
        recorder.beginSegment()
        router.showTeamHome()
        await settle(150)
        router.leaveTeamHome()
        await settle(20)
        recorder.endSegment("avatars")
        return "the quick open palette, the usage popover, a sheet and a toast opened and closed, then the team home left alone for 2.5 s (avatars)"
    }
}
#endif
