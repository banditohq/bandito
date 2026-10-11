import BanditoKit
import Foundation
import os

#if os(macOS)
import CoreFoundation

/// The state of the main run loop as the hang detector sees it. Pure (the clock is passed in), so it is tested alone.
///
/// The main thread reports two moments: it wakes up with work (`wake`) and goes back to sleep (`sleep`). Between them it
/// is busy. A hang is a busy stretch of `threshold` or more.
struct HangTracker: Equatable {
    /// A busy stretch this long (nanoseconds) is a hang: the interface did not answer for a quarter of a second.
    static let threshold: UInt64 = 250_000_000

    /// When the current busy stretch began; nil while the main thread sleeps in its run loop.
    private(set) var busySince: UInt64?
    /// The stretch in progress was already announced by the watcher.
    private(set) var announced = false
    /// The length of the stretch the last `sleep` closed, hang or not (0 when none was running).
    private(set) var lastLength: UInt64 = 0

    /// The main thread woke up. A wake inside a stretch that is already running (the loop did not sleep) changes nothing.
    mutating func wake(at now: UInt64) {
        if busySince == nil {
            busySince = now
            announced = false
        }
    }

    /// The main thread is about to sleep. The length of the stretch when it was a hang, else nil.
    mutating func sleep(at now: UInt64) -> UInt64? {
        defer {
            busySince = nil
            announced = false
        }
        lastLength = 0
        guard let start = busySince, now >= start else { return nil }
        let length = now - start
        lastLength = length
        return length >= Self.threshold ? length : nil
    }

    /// Called by the watcher: true once per stretch, when it has been busy for the threshold and was not announced yet.
    mutating func shouldAnnounce(at now: UInt64) -> Bool {
        guard let start = busySince, !announced, now >= start, now - start >= Self.threshold else { return false }
        announced = true
        return true
    }
}

/// Finds freezes of the main thread, in release builds too. One run loop observer on the main thread (a lock and two
/// stores per wake-up, no allocation) and one coarse timer on a background queue (every 100 ms, nothing allocated while
/// the main thread is idle).
///
/// A hang of 250 ms or more goes to the unified log (`dev.bandito` / `perf`) with its length, the screen and the last
/// action the app knows, and to the anonymous counter `perf.hang.<screen>` (only when statistics are on). No stack
/// and no content: the action is one of a few fixed words.
@MainActor
public enum HangMonitor {
    private struct Shared {
        var tracker = HangTracker()
        var screen: TelemetryEvent.HangScreen = .other
        var action: StaticString = "start"
        var actionAt: UInt64 = 0
        /// QA only: the time the main thread was busy since the last `takeBusy`, while `metering`.
        var busyAccum: UInt64 = 0
        var metering = false
        /// When the busy stretch in progress began, and when `takeBusy` last ran: a stretch is counted from the later
        /// of the two, so the part of a long stretch that falls in a frame is counted in that frame.
        var meterFrom: UInt64 = 0
        var lastTake: UInt64 = 0
        /// While `metering`: busy stretches of `longStretch` or more that ended since the last `takeLongStretches`.
        var longStretches = 0
    }

    /// A busy stretch this long (nanoseconds) is counted by the smoothness check: a freeze anyone sees.
    nonisolated static let longStretch: UInt64 = 100_000_000

    private nonisolated static let state = OSAllocatedUnfairLock(initialState: Shared())
    private nonisolated static let log = Logger(subsystem: "dev.bandito", category: "perf")
    private static var observer: CFRunLoopObserver?
    private static var timer: DispatchSourceTimer?
    private static var onHang: (@MainActor (UInt64) -> Void)?
    /// Hangs seen since the start, for the QA scenarios.
    private(set) static var hangCount = 0

    /// Starts watching. Once; later calls do nothing.
    public static func start() {
        guard observer == nil, let made = makeObserver() else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
        observer = made
        // The loop is running right now (this is called from it), so this stretch is busy from here.
        state.withLock { $0.tracker.wake(at: now()) }
        let source = makeTimer()
        source.resume()
        timer = source
    }

    /// Built outside the main actor on purpose: a closure made inside it asserts that it runs on the main queue, and
    /// the timer's handler runs on a background one.
    private nonisolated static func makeTimer() -> DispatchSourceTimer {
        let queue = DispatchQueue(label: "dev.bandito.hang-watch", qos: .utility)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(50))
        source.setEventHandler { watch() }
        return source
    }

    private nonisolated static func makeObserver() -> CFRunLoopObserver? {
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        return CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, Int.max) { _, activity in
            // Always the main thread, inside its run loop.
            if activity == .afterWaiting {
                state.withLock { shared in
                    let at = now()
                    if shared.tracker.busySince == nil { shared.meterFrom = at }
                    shared.tracker.wake(at: at)
                }
            } else {
                let result: (UInt64, TelemetryEvent.HangScreen, StaticString, UInt64)? = state.withLock { shared in
                    let at = now()
                    let wasBusy = shared.tracker.busySince != nil
                    let hang = shared.tracker.sleep(at: at)
                    if shared.metering, wasBusy {
                        shared.busyAccum &+= at &- max(shared.meterFrom, shared.lastTake)
                        if shared.tracker.lastLength >= longStretch { shared.longStretches += 1 }
                    }
                    return hang.map { ($0, shared.screen, shared.action, shared.actionAt) }
                }
                if let result { MainActor.assumeIsolated { finished(result.0, result.1, result.2, result.3) } }
            }
        }
    }

    /// The screen in front. Set by the router.
    public static func note(screen: AppMode) {
        let mapped = TelemetryEvent.HangScreen(rawValue: screen.rawValue) ?? .other
        state.withLock { $0.screen = mapped }
    }

    /// The last thing the person (or a QA scenario) did, as a fixed word such as "mode.switch". A literal only: the
    /// compiler keeps content and ids out of it.
    public static func note(action: StaticString) {
        let at = now()
        state.withLock {
            $0.action = action
            $0.actionAt = at
        }
    }

    /// The performance scenarios (QA and the smoothness check): starts or stops adding up the time the main thread is busy (a lock and an add per wake-up).
    static func meter(_ on: Bool) {
        state.withLock {
            $0.metering = on
            $0.busyAccum = 0
            $0.longStretches = 0
            $0.lastTake = now()
        }
    }

    /// The busy stretches of 100 ms or more that ended since the last call, and back to zero.
    static func takeLongStretches() -> Int {
        state.withLock { shared in
            defer { shared.longStretches = 0 }
            return shared.longStretches
        }
    }

    /// The busy time in nanoseconds since the last call, and back to zero. A stretch still going counts up to now.
    static func takeBusy() -> UInt64 {
        state.withLock { shared in
            let at = now()
            if shared.tracker.busySince != nil { shared.busyAccum &+= at &- max(shared.meterFrom, shared.lastTake) }
            shared.lastTake = at
            defer { shared.busyAccum = 0 }
            return shared.busyAccum
        }
    }

    /// Runs `body` after each hang, with its length in nanoseconds (the QA scenarios read it). One observer at a time.
    static func observeHangs(_ body: (@MainActor (UInt64) -> Void)?) { onHang = body }

    private nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Background tick: announces a stretch that is still going, so a hang that never ends (or ends in a kill) is in the
    /// log. Reads the state under the lock only.
    private nonisolated static func watch() {
        let announce: (TelemetryEvent.HangScreen, StaticString)? = state.withLock { shared in
            shared.tracker.shouldAnnounce(at: now()) ? (shared.screen, shared.action) : nil
        }
        if let announce {
            log.notice("main thread busy over 250 ms: screen \(announce.0.rawValue, privacy: .public) after \(String(describing: announce.1), privacy: .public)")
        }
    }

    private static func finished(
        _ length: UInt64, _ screen: TelemetryEvent.HangScreen, _ action: StaticString, _ actionAt: UInt64
    ) {
        hangCount += 1
        let ms = Int(length / 1_000_000)
        let ago = actionAt == 0 ? -1 : Int((now() &- actionAt) / 1_000_000)
        log.notice("hang \(ms, privacy: .public) ms: screen \(screen.rawValue, privacy: .public) after \(String(describing: action), privacy: .public) \(ago, privacy: .public) ms ago")
        Telemetry.count(.hang(screen))
        onHang?(length)
    }
}
#endif
