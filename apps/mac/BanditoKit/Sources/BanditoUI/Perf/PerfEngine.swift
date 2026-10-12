#if os(macOS)
import AppKit
import BanditoKit
import Foundation
import QuartzCore

// The measuring part of the performance scenarios: frames, the main thread's work in each frame, long stretches, memory.
// Used by the smoothness check (Help menu, release builds too) and by the QA command `perf` (debug builds).

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
    /// The time the main thread worked in each frame (the sum of its busy stretches between two frames). This is what
    /// decides a 120 Hz screen, where a frame has 8.3 ms, whatever the screen of the machine that measures.
    var workP50Ms: Double
    var workP95Ms: Double
    var workWorstMs: Double
    /// The processor time the main thread used in each frame (a cross-check of `work`: work that waits is not in it).
    var cpuP50Ms: Double = 0
    var cpuP95Ms: Double = 0
    /// The share of frames (0...1) whose main-thread work took more than 8.33 ms (a 120 Hz frame).
    var shareOver8Ms: Double
    /// The share of frames (0...1) that missed even a 60 Hz frame: work over 16.67 ms, or a gap over 1.25 × 16.67 ms.
    var shareOver16Ms: Double
    /// Busy stretches of the main thread of 100 ms or more: freezes anyone sees.
    var stretchesOver100Ms: Int = 0
    /// Sheets that slid in or out (`SheetSlideRule`): the main thread waited in AppKit's animation loop, the window's
    /// display link did not tick. Not frames of this window: counted apart, with the longest.
    var sheetSlides: Int = 0
    var sheetSlideWorstMs: Double = 0
    /// The frames over 50 ms (their gap or their work), at most 12 of the worst: where a hitch came from.
    var longFrames: [LongFrame]? = nil

    /// One long frame: its place in the run, its gap, the main thread's work and processor time in it, and whether its
    /// gap was a sheet's slide.
    struct LongFrame: Equatable, Codable, Sendable {
        var index: Int
        var gapMs: Double
        var workMs: Double
        var cpuMs: Double
        var slide: Bool
    }

    /// - Parameters:
    ///   - intervals: seconds between each frame callback and the one before.
    ///   - work: seconds the main thread worked in each frame; may be empty when it was not measured.
    ///   - cpu: seconds of processor time the main thread used in each frame; may be empty.
    ///   - longStretches: busy stretches of 100 ms or more that ended during the run.
    ///   - frameDuration: the display's frame time in seconds.
    ///   - slides: the frames (by index) whose gap was a sheet's slide; they are left out and counted apart.
    static func compute(
        intervals allIntervals: [Double], work allWork: [Double] = [], cpu allCPU: [Double] = [], longStretches: Int = 0,
        frameDuration: Double, slides: [Bool] = []
    ) -> FrameStats {
        // A slide's gap is not a frame of this window; the work in it (the sheet's building) still is work.
        func isSlide(_ index: Int) -> Bool { index < slides.count && slides[index] }
        let slid = allIntervals.indices.filter(isSlide)
        let intervals = allIntervals.indices.filter { !isSlide($0) }.map { allIntervals[$0] }
        let work = allWork
        let cpu = allCPU
        let duration = frameDuration > 0 ? frameDuration : 1.0 / 60.0
        func percentile(_ sorted: [Double], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[index]
        }
        func rounded(_ share: Double) -> Double { (share * 1000).rounded() / 1000 }
        let sortedWork = work.sorted()
        let sortedCPU = cpu.sorted()
        let over8 = work.isEmpty ? 0 : Double(work.filter { $0 > PerfBudget.frame120 }.count) / Double(work.count)
        var late = 0
        for index in allIntervals.indices {
            let gap = isSlide(index) ? 0 : allIntervals[index]
            let busy = index < work.count ? work[index] : 0
            if gap > PerfBudget.frame60 * 1.25 || busy > PerfBudget.frame60 { late += 1 }
        }
        let over16 = allIntervals.isEmpty ? 0 : Double(late) / Double(allIntervals.count)
        let sorted = intervals.sorted()
        let missed = intervals.filter { $0 > 1.5 * duration }.count
        let dropped = intervals.reduce(0) { total, gap in
            gap > 1.5 * duration ? total + max(0, Int((gap / duration).rounded()) - 1) : total
        }
        var long: [LongFrame] = []
        for index in allIntervals.indices {
            let gap = allIntervals[index]
            let busy = index < work.count ? work[index] : 0
            guard gap > 0.05 || busy > 0.05 else { continue }
            long.append(LongFrame(
                index: index, gapMs: gap * 1000, workMs: busy * 1000, cpuMs: (index < cpu.count ? cpu[index] : 0) * 1000,
                slide: isSlide(index)))
        }
        long = Array(long.sorted { max($0.gapMs, $0.workMs) > max($1.gapMs, $1.workMs) }.prefix(12))
        return FrameStats(
            frames: intervals.count, missed: missed, droppedEstimate: dropped,
            worstFrameMs: (sorted.last ?? 0) * 1000, p50Ms: percentile(sorted, 0.5) * 1000,
            p95Ms: percentile(sorted, 0.95) * 1000, frameDurationMs: duration * 1000,
            workP50Ms: percentile(sortedWork, 0.5) * 1000, workP95Ms: percentile(sortedWork, 0.95) * 1000,
            workWorstMs: (sortedWork.last ?? 0) * 1000, cpuP50Ms: percentile(sortedCPU, 0.5) * 1000,
            cpuP95Ms: percentile(sortedCPU, 0.95) * 1000, shareOver8Ms: rounded(over8), shareOver16Ms: rounded(over16),
            stretchesOver100Ms: longStretches, sheetSlides: slid.count,
            sheetSlideWorstMs: (slid.map { allIntervals[$0] }.max() ?? 0) * 1000, longFrames: long.isEmpty ? nil : long)
    }

    /// The owner's bar for a release: on the screen that measures, no frame is late (p95 of the gaps within 15 % of its
    /// frame), the main thread's work fits a 120 Hz frame (p95 ≤ 8.3 ms), fewer than 1 % of frames miss a 60 Hz frame,
    /// and nothing freezes for 100 ms.
    func meetsTarget(displayFrameMs: Double) -> Bool {
        guard frames > 0 else { return false }
        let frame = displayFrameMs > 0 ? displayFrameMs : 1000.0 / 60
        return p95Ms <= frame * 1.15 && workP95Ms <= PerfBudget.frame120 * 1000 && shareOver16Ms < 0.01
            && stretchesOver100Ms == 0
    }
}

/// Frame budgets in seconds.
enum PerfBudget {
    static let frame120 = 1.0 / 120
    static let frame60 = 1.0 / 60
}

/// One part of a run that has several (a mode, a section of Settings).
struct PerfSegment: Codable, Sendable, Equatable {
    var name: String
    var frames: FrameStats
    var meetsTarget: Bool
}

/// The result of one scenario: the JSON file of a QA run, a row of the smoothness check.
struct PerfReport: Codable, Sendable, Equatable {
    var scenario: String
    var startedAt: String
    var durationSec: Double
    var frames: FrameStats
    /// Main-thread hangs of 250 ms or more (`HangMonitor`).
    var hangs: Int
    var longestHangMs: Double
    var memoryStartMB: Double
    var memoryPeakMB: Double
    var memoryEndMB: Double
    /// The parts of a run that has several (one per mode, one per section).
    var segments: [PerfSegment]
    /// Frames the display link never delivered (paced by a timer instead). A run with many of them measures nothing.
    var silentFrames: Int
    /// How often the key views built their body during the run (see `PerfCounters`, debug builds only).
    var bodies: [String: Int]
    /// What the scenario did, in words ("1500 rows, 9 sweeps"), or why it could not run.
    var note: String
    var error: String?
    /// The most frames a second the screen of the window can show (`NSScreen.maximumFramesPerSecond`).
    var screenFPS: Int = 60
    var meetsTarget = false

    /// Where a QA run's file goes: the given path, else `~/.cache/bandito-qa/perf-<scenario>.json`.
    static func destination(scenario: String, path: String?) -> URL {
        if let path, !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/bandito-qa/perf-\(scenario).json")
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

/// The processor time the calling thread has used, in seconds.
func currentThreadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, port) }
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
    let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    return user + system
}

/// A wait for the next frame that is resumed once, by the display link or by its fallback timer.
@MainActor
final class FrameWaiter {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    /// Resumes a wait that is still open (the timer's turn). False when the display link got there first.
    func resumeIfWaiting() -> Bool {
        guard continuation != nil else { return false }
        resumeOnce()
        return true
    }

    func resumeOnce() {
        guard let continuation else { return }
        continuation.resume()
        self.continuation = nil
    }
}

/// Counts the frames of a window with a display link and hands out "the next frame" to the scenario.
@MainActor
final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var lastCPU: Double = 0
    private var intervals: [Double] = []
    private var work: [Double] = []
    private var cpu: [Double] = []
    /// Busy stretches of 100 ms or more, by the frame they ended in.
    private var long: [Int] = []
    /// Frames whose gap was a sheet's slide (see `FrameStats.sheetSlides`).
    private var slid: [Bool] = []
    private var segmentStart = 0
    private(set) var segments: [PerfSegment] = []
    private(set) var frameDuration: Double = 0
    private var waiters: [FrameWaiter] = []
    private(set) var peakFootprint: UInt64 = 0
    private var ticks = 0
    private(set) var recording = false
    /// Frames the display link did not deliver: the run was paced by the fallback timer (the window was not drawn).
    private(set) var silentFrames = 0
    /// The display's frame in milliseconds, for the verdicts.
    var displayFrameMs: Double { frameDuration > 0 ? frameDuration * 1000 : 1000.0 / 60 }

    init(view: NSView) {
        super.init()
        bind(to: view)
        intervals.reserveCapacity(20_000)
        work.reserveCapacity(20_000)
        cpu.reserveCapacity(20_000)
        long.reserveCapacity(20_000)
    }

    /// Counts the frames of another view's window from now on.
    func rebind(to view: NSView) {
        link?.invalidate()
        bind(to: view)
        last = nil
    }

    private func bind(to view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A part of the run starts here; `endSegment` closes it with a name.
    func beginSegment() { segmentStart = intervals.count }

    func endSegment(_ name: String) {
        let from = min(segmentStart, intervals.count)
        let stats = FrameStats.compute(
            intervals: Array(intervals[from...]), work: Array(work[min(from, work.count)...]),
            cpu: Array(cpu[min(from, cpu.count)...]), longStretches: long[min(from, long.count)...].reduce(0, +),
            frameDuration: frameDuration, slides: Array(slid[min(from, slid.count)...]))
        segments.append(PerfSegment(name: name, frames: stats, meetsTarget: stats.meetsTarget(displayFrameMs: displayFrameMs)))
    }

    /// Starts counting. The frames before it only pace the scenario.
    func begin() {
        intervals.removeAll(keepingCapacity: true)
        work.removeAll(keepingCapacity: true)
        cpu.removeAll(keepingCapacity: true)
        long.removeAll(keepingCapacity: true)
        slid.removeAll(keepingCapacity: true)
        _ = HangMonitor.takeSlides()
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
        // A stretch that ended after the last frame still counts.
        if !long.isEmpty { long[long.count - 1] += HangMonitor.takeLongStretches() }
        HangMonitor.meter(false)
        peakFootprint = max(peakFootprint, physicalFootprintBytes())
        return FrameStats.compute(
            intervals: intervals, work: work, cpu: cpu, longStretches: long.reduce(0, +), frameDuration: frameDuration,
            slides: slid)
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
            let stretches = HangMonitor.takeLongStretches()
            let slides = HangMonitor.takeSlides()
            let cpuNow = currentThreadCPUSeconds()
            if let last {
                intervals.append(now - last)
                work.append(busy)
                cpu.append(max(0, cpuNow - lastCPU))
                long.append(stretches)
                // The gap before this frame held a sheet's slide: the display link stood still for it.
                slid.append(slides > 0 && now - last > 1.5 * max(frameDuration, 1.0 / 120))
            }
            last = now
            lastCPU = cpuNow
            ticks += 1
            if ticks % 15 == 0 { peakFootprint = max(peakFootprint, physicalFootprintBytes()) }
        }
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resumeOnce() }
    }
}

/// Finds and moves the scroll views of a screen.
@MainActor
enum PerfScroller {
    /// The biggest scroll view of the window that has more to show than fits, scrolling up and down.
    static func main(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        return main(under: root)
    }

    /// Drawn at no opacity (a page kept alive under another, as the main window under Settings in the check).
    static func isFaded(_ view: NSView) -> Bool {
        var layer = view.layer
        while let current = layer {
            if current.opacity == 0 || current.isHidden { return true }
            layer = current.superlayer
        }
        return false
    }

    static func main(under root: NSView) -> NSScrollView? {
        var best: (NSScrollView, CGFloat)?
        func visit(_ view: NSView) {
            if !view.isHidden, let scroll = view as? NSScrollView, let document = scroll.documentView,
                document.frame.height > scroll.contentView.bounds.height + 100, scroll.window != nil,
                !PerfScroller.isFaded(scroll)
            {
                let area = scroll.contentView.bounds.width * scroll.contentView.bounds.height
                if best == nil || area > best!.1 { best = (scroll, area) }
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return best?.0
    }

    /// The scroll view whose frame, in window coordinates, contains `point` and that scrolls (the innermost one).
    static func at(_ point: NSPoint, in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var found: NSScrollView?
        func visit(_ view: NSView) {
            if !view.isHidden, let scroll = view as? NSScrollView, let document = scroll.documentView,
                document.frame.height > scroll.contentView.bounds.height + 20,
                scroll.convert(scroll.bounds, to: nil).contains(point)
            {
                found = scroll
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return found
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

/// A line per step of a run, in `~/.cache/bandito-qa/perf-trace.log` of a QA copy: what a run that does not end was
/// doing last. Nothing in a release build.
enum PerfTrace {
    static func write(_ text: String) {
        #if DEBUG
        guard QABuild.isRunningQA else { return }
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
        #endif
    }
}
#endif
