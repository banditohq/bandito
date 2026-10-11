#if DEBUG && os(macOS)
import AppKit
import BanditoKit
import BanditoL10n
import Foundation
import QuartzCore

// Performance scenarios for the QA copies (`perf <scenario> [result path]`, see `QAHooks`). Each one drives the
// interface the way a person would (scroll, open and close a panel, switch, type), counts the frames the window draws
// meanwhile, and writes one JSON file. Debug builds only; they run on synthetic data (`PerfFixtures`).

/// The scenarios, by the word that follows `perf`.
enum PerfScenario: String, CaseIterable, Sendable {
    case thread, threadfast, inspector, market, `switch`, typing, settings, modes
}

/// What the frames of a run came to. Pure, so it is tested alone.
struct FrameStats: Equatable, Codable, Sendable {
    var frames: Int
    /// Frames that came later than 1.5 frame durations after the one before.
    var missed: Int
    /// Frames lost in all: a gap of 100 ms at 60 Hz loses about five. `missed` counts the gap once.
    var droppedEstimate: Int
    var worstFrameMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var frameDurationMs: Double
    /// The time the main thread worked in each frame (the sum of its busy stretches between two frames). This is the
    /// number that matters on a 120 Hz screen, where a frame has 8.3 ms: the VM draws at 60 Hz, so the budget is
    /// read from the work, not from the gaps.
    var workP50Ms: Double
    var workP95Ms: Double
    var workWorstMs: Double
    /// The share of frames (0...1) whose main-thread work took more than 8.33 ms (a 120 Hz frame) and 16.67 ms.
    var shareOver8Ms: Double
    var shareOver16Ms: Double

    /// - Parameters:
    ///   - intervals: seconds between each frame callback and the one before.
    ///   - work: seconds the main thread worked in each frame; may be empty when it was not measured.
    ///   - frameDuration: the display's frame time in seconds.
    static func compute(intervals: [Double], work: [Double] = [], frameDuration: Double) -> FrameStats {
        let duration = frameDuration > 0 ? frameDuration : 1.0 / 60.0
        func percentile(_ sorted: [Double], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[index]
        }
        let sortedWork = work.sorted()
        func share(over limit: Double) -> Double {
            guard !work.isEmpty else { return 0 }
            return (Double(work.filter { $0 > limit }.count) / Double(work.count) * 1000).rounded() / 1000
        }
        let sorted = intervals.sorted()
        let missed = intervals.filter { $0 > 1.5 * duration }.count
        let dropped = intervals.reduce(0) { total, gap in
            gap > 1.5 * duration ? total + max(0, Int((gap / duration).rounded()) - 1) : total
        }
        return FrameStats(
            frames: intervals.count, missed: missed, droppedEstimate: dropped,
            worstFrameMs: (sorted.last ?? 0) * 1000, p50Ms: percentile(sorted, 0.5) * 1000,
            p95Ms: percentile(sorted, 0.95) * 1000, frameDurationMs: duration * 1000,
            workP50Ms: percentile(sortedWork, 0.5) * 1000, workP95Ms: percentile(sortedWork, 0.95) * 1000,
            workWorstMs: (sortedWork.last ?? 0) * 1000, shareOver8Ms: share(over: 1.0 / 120.0),
            shareOver16Ms: share(over: 1.0 / 60.0))
    }
}

/// One part of a run that has several (a mode, a section of Settings).
struct PerfSegment: Codable, Sendable {
    var name: String
    var frames: FrameStats
}

/// The JSON file of one run.
struct PerfReport: Codable, Sendable {
    var scenario: String
    var startedAt: String
    var durationSec: Double
    var frames: FrameStats
    var hangs: Int
    var longestHangMs: Double
    var memoryStartMB: Double
    var memoryPeakMB: Double
    var memoryEndMB: Double
    /// The parts of a run that has several (one per mode, one per section).
    var segments: [PerfSegment]
    /// Frames the display link never delivered (paced by a timer instead). A run with many of them measures nothing.
    var silentFrames: Int
    /// How often the key views built their body during the run (see `PerfCounters`).
    var bodies: [String: Int]
    /// What the scenario did, in words ("1500 rows, 9 sweeps"), or why it could not run.
    var note: String
    var error: String?

    /// Where the file goes: the given path, else `~/.cache/bandito-qa/perf-<scenario>.json`.
    static func destination(scenario: PerfScenario, path: String?) -> URL {
        if let path, !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/bandito-qa/perf-\(scenario.rawValue).json")
    }
}

/// The footprint the system charges to this process, in bytes (what Activity Monitor calls "Memory").
func physicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// A wait for the next frame that is resumed once, by the display link or by its fallback timer.
@MainActor
final class FrameWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    /// Set when the timer, not the display link, ended the wait.
    private(set) var timedOut = false

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    /// Resumes a wait that is still open (the timer's turn). False when the display link got there first.
    func resumeIfWaiting() -> Bool {
        guard continuation != nil else { return false }
        resumeOnce(byTimer: true)
        return true
    }

    func resumeOnce(byTimer: Bool = false) {
        guard let continuation else { return }
        if byTimer { timedOut = true }
        continuation.resume()
        self.continuation = nil
    }
}

/// Counts the frames of a window with a display link and hands out "the next frame" to the scenario.
@MainActor
final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var intervals: [Double] = []
    private var work: [Double] = []
    private var segmentStart = 0
    private(set) var segments: [PerfSegment] = []
    private var frameDuration: Double = 0
    private var waiters: [FrameWaiter] = []
    private(set) var peakFootprint: UInt64 = 0
    private var ticks = 0
    private(set) var recording = false
    /// Frames the display link did not deliver: the run was paced by the fallback timer (the window was not drawn).
    private(set) var silentFrames = 0

    init(view: NSView) {
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        intervals.reserveCapacity(20_000)
        work.reserveCapacity(20_000)
    }

    /// Counts the frames of another window from now on (the Settings window has its own display link).
    func rebind(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        last = nil
    }

    /// A part of the run starts here; `endSegment` closes it with a name.
    func beginSegment() { segmentStart = intervals.count }

    func endSegment(_ name: String) {
        let from = min(segmentStart, intervals.count)
        let slice = Array(intervals[from...])
        let workSlice = Array(work[min(from, work.count)...])
        segments.append(PerfSegment(name: name, frames: FrameStats.compute(intervals: slice, work: workSlice, frameDuration: frameDuration)))
    }

    /// Starts counting. The frames before it only pace the scenario.
    func begin() {
        intervals.removeAll(keepingCapacity: true)
        work.removeAll(keepingCapacity: true)
        segments.removeAll()
        segmentStart = 0
        last = nil
        HangMonitor.meter(true)
        PerfCounters.reset()
        PerfCounters.counting = true
        peakFootprint = physicalFootprintBytes()
        recording = true
    }

    func finish() -> FrameStats {
        recording = false
        PerfCounters.counting = false
        HangMonitor.meter(false)
        peakFootprint = max(peakFootprint, physicalFootprintBytes())
        return FrameStats.compute(intervals: intervals, work: work, frameDuration: frameDuration)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        for waiter in waiters { waiter.resumeOnce() }
        waiters.removeAll()
    }

    /// Returns at the next frame. A scenario takes one step per frame, so a stall slows the scenario down instead of
    /// piling steps up behind it.
    func nextFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = FrameWaiter(continuation)
            waiters.append(waiter)
            // A display link that does not fire (a window nobody can see) must not stop a run for good.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if waiter.resumeIfWaiting() { self?.silentFrames += 1 }
            }
        }
    }

    func frames(_ count: Int) async {
        for _ in 0..<count { await nextFrame() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let duration = link.targetTimestamp - link.timestamp
        if duration > 0 { frameDuration = duration }
        if recording {
            let busy = Double(HangMonitor.takeBusy()) / 1_000_000_000
            if let last {
                intervals.append(now - last)
                work.append(busy)
            }
            last = now
            ticks += 1
            if ticks % 15 == 0 { peakFootprint = max(peakFootprint, physicalFootprintBytes()) }
        }
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resumeOnce() }
    }
}

/// Finds and moves the scroll view that carries a screen's main content.
@MainActor
enum PerfScroller {
    /// The biggest scroll view of the window that has more to show than fits.
    static func main(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var best: (NSScrollView, CGFloat)?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
                document.frame.height > scroll.contentView.bounds.height + 100
            {
                let area = scroll.contentView.bounds.width * scroll.contentView.bounds.height
                if best == nil || area > best!.1 { best = (scroll, area) }
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return best?.0
    }

    static func offset(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.origin.y }

    static func maxOffset(_ scroll: NSScrollView) -> CGFloat {
        max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
    }

    /// Scrolls to `y` (clamped), as a wheel would: through the clip view, so the scroll notifications fire.
    static func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), maxOffset(scroll))))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: sideways

    /// The scroll views of the window that have more to show sideways than fits (the Marketplace shelves), the highest
    /// on the screen first.
    static func shelves(in window: NSWindow) -> [NSScrollView] {
        guard let root = window.contentView else { return [] }
        var found: [(NSScrollView, CGFloat)] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
                document.frame.width > scroll.contentView.bounds.width + 50,
                document.frame.height <= scroll.contentView.bounds.height + 1
            {
                found.append((scroll, scroll.convert(scroll.bounds, to: nil).maxY))
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func offsetX(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.origin.x }

    /// Where the row starts: the page margin is a content inset, so the first card sits at a negative offset.
    static func minOffsetX(_ scroll: NSScrollView) -> CGFloat { -scroll.contentInsets.left }

    static func maxOffsetX(_ scroll: NSScrollView) -> CGFloat {
        max(
            minOffsetX(scroll),
            (scroll.documentView?.frame.width ?? 0) + scroll.contentInsets.right - scroll.contentView.bounds.width)
    }

    /// Scrolls to `x` (clamped), as a trackpad would: through the clip view, so the scroll notifications fire.
    static func scrollX(_ scroll: NSScrollView, to x: CGFloat) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: min(max(minOffsetX(scroll), x), maxOffsetX(scroll)), y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
    }

    /// The text field of the window with this placeholder.
    static func textField(in window: NSWindow, placeholder: String) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: NSTextField?
        func visit(_ view: NSView) {
            if found != nil { return }
            if let field = view as? NSTextField, field.isEditable,
                (field.placeholderString ?? field.placeholderAttributedString?.string) == placeholder
            {
                found = field
                return
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return found
    }
}

/// A line per step of a run, in `~/.cache/bandito-qa/perf-trace.log`: what a run that does not end was doing last.
enum PerfTrace {
    static func write(_ text: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/bandito-qa/perf-trace.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

@MainActor
enum PerfScenarios {
    private static var running: PerfScenario?

    /// Starts a scenario in the background. One at a time; the answer is the file (and a line in the log).
    static func start(_ scenario: PerfScenario, path: String?, router: Router, app: AppModel?) {
        PerfTrace.write("command \(scenario.rawValue) (running: \(running?.rawValue ?? "none"))")
        guard running == nil else {
            NSLog("QA perf: \(running?.rawValue ?? "?") is still running; \(scenario.rawValue) ignored")
            return
        }
        running = scenario
        NSLog("QA perf \(scenario.rawValue) started")
        let destination = PerfReport.destination(scenario: scenario, path: path)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        Task { @MainActor in
            let report = await run(scenario, router: router, app: app)
            write(report, to: destination)
            running = nil
            NSLog("QA perf \(scenario.rawValue) done: \(destination.path)")
        }
    }

    private static func write(_ report: PerfReport, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

    private static func run(_ scenario: PerfScenario, router: Router, app: AppModel?) async -> PerfReport {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        func failed(_ why: String) -> PerfReport {
            PerfReport(
                scenario: scenario.rawValue, startedAt: startedAt, durationSec: 0,
                frames: FrameStats.compute(intervals: [], frameDuration: 0), hangs: 0, longestHangMs: 0,
                memoryStartMB: 0, memoryPeakMB: 0, memoryEndMB: 0, segments: [], silentFrames: 0, bodies: [:], note: "", error: why)
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }),
            let content = window.contentView
        else { return failed("no main window") }
        guard let server = app?.currentServer else { return failed("no server selected") }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        PerfTrace.write("\(scenario.rawValue): window found")

        let recorder = FrameRecorder(view: content)
        defer { recorder.invalidate() }
        let tally = HangTally()
        HangMonitor.observeHangs { length in tally.add(length) }
        defer { HangMonitor.observeHangs(nil) }

        let before = (mode: router.mode, agent: router.selectedAgentID)
        let context = PerfContext(router: router, server: server, window: window, recorder: recorder)
        HangMonitor.note(action: "qa.perf")
        let memoryStart = physicalFootprintBytes()
        let began = CACurrentMediaTime()
        var note = ""
        var error: String?
        do {
            switch scenario {
            case .thread: note = try await context.thread()
            case .threadfast: note = try await context.threadFast()
            case .settings: note = try await context.settings()
            case .modes: note = try await context.modes()
            case .inspector: note = try await context.inspector()
            case .market: note = try await context.market()
            case .switch: note = try await context.switchAll()
            case .typing: note = try await context.typing()
            }
        } catch let problem as PerfProblem {
            error = problem.message
        } catch {
            // Cancellation is the only other failure.
        }
        let stats = recorder.finish()
        let duration = CACurrentMediaTime() - began
        let memoryEnd = physicalFootprintBytes()

        // Leave the app as it was found.
        server.removeSyntheticAgents()
        router.select(mode: before.mode)
        router.selectedAgentID = before.agent
        return PerfReport(
            scenario: scenario.rawValue, startedAt: startedAt, durationSec: (duration * 100).rounded() / 100,
            frames: stats, hangs: tally.count, longestHangMs: (Double(tally.longest) / 10_000).rounded() / 100,
            memoryStartMB: mb(memoryStart), memoryPeakMB: mb(max(recorder.peakFootprint, memoryEnd)),
            memoryEndMB: mb(memoryEnd), segments: recorder.segments, silentFrames: recorder.silentFrames, bodies: PerfCounters.snapshot(), note: note,
            error: error)
    }
}

/// The hangs seen during one run.
@MainActor
final class HangTally {
    private(set) var count = 0
    private(set) var longest: UInt64 = 0

    func add(_ length: UInt64) {
        count += 1
        longest = max(longest, length)
    }
}

struct PerfProblem: Error {
    let message: String
}

/// The steps of the scenarios. Every step waits for a frame, so the counts are the frames of the real interface.
@MainActor
private struct PerfContext {
    let router: Router
    let server: ServerModel
    let window: NSWindow
    let recorder: FrameRecorder

    private func settle(_ frames: Int = 40) async { await recorder.frames(frames) }

    private func scrollView() throws -> NSScrollView {
        guard let scroll = PerfScroller.main(in: window) else { throw PerfProblem(message: "no scroll view to drive") }
        return scroll
    }

    /// Installs a synthetic agent with `rows` rows and opens its chat. The load is not part of the count.
    private func openThread(rows: Int, id: String = PerfFixtures.threadAgentID) async {
        server.installSyntheticAgent(
            PerfFixtures.agent(id: id, name: "Perf Thread", index: 1), items: PerfFixtures.thread(count: rows))
        router.select(mode: .team)
        router.selectedAgentID = id
        PerfTrace.write("thread installed (\(rows) rows), settling")
        await settle(90)
        PerfTrace.write("thread settled")
    }

    /// Scrolls from the current place to `target` at `speed` points a frame; `target` may be recomputed each frame
    /// (the content grows when older rows are added). Gives up after `limit` frames.
    private func sweep(
        _ scroll: NSScrollView, toTop: Bool, speed: CGFloat, perFrame: Int = 1, limit: Int = 4_000,
        seconds: Double = 15
    ) async -> Int {
        var steps = 0
        var quiet = 0
        // A slow build must not make a run endless: every sweep stops after `seconds`, wherever it got to.
        let deadline = CACurrentMediaTime() + seconds
        while steps < limit, CACurrentMediaTime() < deadline {
            await recorder.nextFrame()
            steps += 1
            // A wheel or a trackpad sends several scroll events between two frames: `perFrame` of them.
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

    func thread() async throws -> String {
        await openThread(rows: 1_500)
        let scroll = try scrollView()
        recorder.begin()
        var sweeps = 0
        for _ in 0..<2 {
            _ = await sweep(scroll, toTop: true, speed: 100, seconds: 20)
            _ = await sweep(scroll, toTop: false, speed: 100, seconds: 20)
            sweeps += 1
        }
        await settle(30)
        return "1500 rows, \(sweeps) round trips from the newest message towards the oldest and back, 100 pt a frame, 20 s at most each way"
    }

    func threadFast() async throws -> String {
        await openThread(rows: 1_500)
        let scroll = try scrollView()
        recorder.begin()
        for _ in 0..<3 {
            _ = await sweep(scroll, toTop: true, speed: 60, perFrame: 4, seconds: 10)
            _ = await sweep(scroll, toTop: false, speed: 60, perFrame: 4, seconds: 10)
        }
        await settle(30)
        return "1500 rows, 3 round trips, 4 scroll events of 60 pt in every frame (a hard flick of a trackpad, 14000 pt a second), 10 s at most each way"
    }

    func settings() async throws -> String {
        WindowActions.showSettings()
        await settle(90)
        guard
            let settingsWindow = NSApp.windows.first(where: {
                $0 !== window && $0.isVisible && $0.contentView != nil && $0.canBecomeKey && !($0 is NSPanel)
            }), let settingsContent = settingsWindow.contentView
        else { throw PerfProblem(message: "the Settings window did not open") }
        recorder.rebind(to: settingsContent)
        defer {
            settingsWindow.performClose(nil)
            recorder.rebind(to: window.contentView ?? settingsContent)
        }
        await settle(20)
        recorder.begin()
        for section in SettingsSection.allCases {
            SettingsNavigation.shared.requested = section
            recorder.beginSegment()
            await settle(24)
            if let scroll = PerfScroller.main(in: settingsWindow) {
                _ = await sweep(scroll, toTop: false, speed: 50, limit: 600, seconds: 6)
                _ = await sweep(scroll, toTop: true, speed: 50, limit: 600, seconds: 6)
            }
            recorder.endSegment(section.rawValue)
        }
        return "all \(SettingsSection.allCases.count) sections of Settings: opened, then the long ones scrolled down and up"
    }

    func modes() async throws -> String {
        server.installSyntheticAgent(
            PerfFixtures.agent(id: PerfFixtures.threadAgentID, name: "Perf Thread", index: 1),
            items: PerfFixtures.thread(count: 300))
        router.select(mode: .team)
        router.selectedAgentID = PerfFixtures.threadAgentID
        await settle(60)
        recorder.begin()
        for mode in [AppMode.files, .terminals, .browser, .screen, .market, .team] {
            if mode == .market { for _ in 0..<600 where router.marketCategories.isEmpty { await recorder.nextFrame() } }
            recorder.beginSegment()
            router.select(mode: mode)
            await settle(40)
            if let scroll = PerfScroller.main(in: window) {
                _ = await sweep(scroll, toTop: false, speed: 50, limit: 500, seconds: 6)
                _ = await sweep(scroll, toTop: true, speed: 50, limit: 500, seconds: 6)
            }
            recorder.endSegment(mode.rawValue)
        }
        router.select(mode: .server)
        for section in ServerSection.allCases {
            router.serverSection = section
            recorder.beginSegment()
            await settle(30)
            if let scroll = PerfScroller.main(in: window) {
                _ = await sweep(scroll, toTop: false, speed: 50, limit: 500, seconds: 6)
                _ = await sweep(scroll, toTop: true, speed: 50, limit: 500, seconds: 6)
            }
            recorder.endSegment("server.\(section.rawValue)")
        }
        return "every mode: opened and its main scroll view moved down and up; the Server mode section by section"
    }

    func inspector() async throws -> String {
        await openThread(rows: 300)
        let id = PerfFixtures.threadAgentID
        recorder.begin()
        for _ in 0..<10 {
            router.showInWorkbench(.details, agentID: id)
            await settle(36)
            router.toggleWorkbench()
            await settle(30)
        }
        return "300 rows, the details panel opened and closed 10 times"
    }

    func market() async throws -> String {
        let tab = router.marketTab
        router.select(mode: .market)
        router.marketTab = .services
        router.marketFilter = .all
        router.marketDetail = nil
        defer {
            router.marketTab = tab
            router.marketFilter = .all
            router.marketBotFilter = .all
            router.marketSkillFilter = .all
        }
        // The catalog comes from the daemon: wait for its categories (up to ten seconds) before counting.
        for _ in 0..<600 where router.marketCategories.isEmpty { await recorder.nextFrame() }
        await settle(40)
        let page = try scrollView()
        recorder.begin()

        recorder.beginSegment()
        _ = await sweep(page, toTop: false, speed: 50, seconds: 15)
        recorder.endSegment("scroll down")
        recorder.beginSegment()
        _ = await sweep(page, toTop: true, speed: 50, seconds: 15)
        recorder.endSegment("scroll up")

        // Two shelves moved sideways, like a trackpad: out to the last card and back.
        let lanes = Array(PerfScroller.shelves(in: window).prefix(2))
        guard !lanes.isEmpty else { throw PerfProblem(message: "no shelf to scroll sideways") }
        recorder.beginSegment()
        for lane in lanes {
            _ = await sweepX(lane, toStart: false, speed: 40, seconds: 8)
            _ = await sweepX(lane, toStart: true, speed: 40, seconds: 8)
        }
        recorder.endSegment("shelves sideways")

        // A category's page, the way "All" opens it, and back: the opening and the return are measured on their own,
        // since each makes a whole page.
        let categories = router.marketCategories
        for name in categories.prefix(3) {
            recorder.beginSegment()
            router.marketFilter = .category(name)
            await settle(30)
            recorder.endSegment("open category")
            if let grid = PerfScroller.main(in: window) {
                recorder.beginSegment()
                _ = await sweep(grid, toTop: false, speed: 50, seconds: 5)
                _ = await sweep(grid, toTop: true, speed: 50, seconds: 5)
                recorder.endSegment("category scroll")
            }
            recorder.beginSegment()
            router.marketFilter = .all
            await settle(30)
            recorder.endSegment("back to shelves")
        }

        // The search: a few letters typed into the field, then cleared.
        recorder.beginSegment()
        try await typeInSearch("linear")
        recorder.endSegment("search")
        await settle(20)

        for page in [MarketTab.bots, .skills] where server.supports(page.feature) {
            router.marketTab = page
            await settle(60)
            recorder.beginSegment()
            if let list = PerfScroller.main(in: window) {
                _ = await sweep(list, toTop: false, speed: 50, seconds: 10)
                _ = await sweep(list, toTop: true, speed: 50, seconds: 10)
            }
            if let lane = PerfScroller.shelves(in: window).first {
                _ = await sweepX(lane, toStart: false, speed: 40, seconds: 8)
                _ = await sweepX(lane, toStart: true, speed: 40, seconds: 8)
            }
            recorder.endSegment(page.rawValue)
        }
        return "Marketplace: the Services page swept down and up at 50 pt a frame, two shelves out and back at 40 pt a frame, \(min(categories.count, 3)) category pages opened and swept, a search typed, then the Bots and Skills pages swept and one shelf moved"
    }

    /// Types `text` into the Marketplace search field one letter a frame, as a person would, and clears the field.
    private func typeInSearch(_ text: String) async throws {
        guard let field = PerfScroller.textField(in: window, placeholder: L10n.Market.search) else {
            throw PerfProblem(message: "the search field was not found")
        }
        window.makeFirstResponder(field)
        await settle(4)
        guard let editor = window.firstResponder as? NSTextView else {
            throw PerfProblem(message: "the search field did not take focus")
        }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await recorder.nextFrame()
        }
        await settle(30)
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        await settle(30)
        window.makeFirstResponder(nil)
    }

    /// Moves a shelf sideways from where it is to its last card (or its first), `speed` points a frame.
    private func sweepX(_ scroll: NSScrollView, toStart: Bool, speed: CGFloat, seconds: Double) async -> Int {
        var steps = 0
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            await recorder.nextFrame()
            steps += 1
            let x = PerfScroller.offsetX(scroll)
            if toStart {
                if x <= PerfScroller.minOffsetX(scroll) + 1 { break }
                PerfScroller.scrollX(scroll, to: x - speed)
            } else {
                if x >= PerfScroller.maxOffsetX(scroll) - 1 { break }
                PerfScroller.scrollX(scroll, to: x + speed)
            }
        }
        return steps
    }

    func switchAll() async throws -> String {
        for index in 1...20 {
            server.installSyntheticAgent(
                PerfFixtures.agent(id: "qa-perf-\(index)", name: "Perf \(index)", index: index),
                items: PerfFixtures.thread(count: 80, seed: UInt64(index)))
        }
        router.select(mode: .team)
        await settle(60)
        recorder.begin()
        for index in 1...20 {
            router.selectedAgentID = "qa-perf-\(index)"
            await settle(10)
        }
        for _ in 0..<2 {
            for mode in AppMode.allCases {
                router.select(mode: mode)
                await settle(40)
            }
        }
        return "20 agents of 80 rows switched one after the other, then all 7 modes twice"
    }

    func typing() async throws -> String {
        await openThread(rows: 400)
        let id = PerfFixtures.threadAgentID
        router.requestComposerFocus(agentID: id)
        await settle(30)
        guard let editor = window.firstResponder as? NSTextView else {
            throw PerfProblem(message: "the composer did not take focus")
        }
        let words = "the quick brown fox jumps over the lazy dog while the agent reads every file in the folder "
        let text = Array(String(String(repeating: words, count: 4).prefix(300)))
        recorder.begin()
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await recorder.nextFrame()
        }
        await settle(20)
        // Leave the draft empty.
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        return "400 rows, 300 characters typed into the composer, one a frame"
    }
}
#endif
