import BackgroundTasks
import Foundation

/// The background check: an app refresh task about every 15 minutes (`BGAppRefreshTask`). Without push this is best
/// effort: iOS decides when it runs, and it may skip the run altogether (docs/IOS_APP.md, Reliability).
enum BackgroundRefresh {
    /// Listed in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    static let taskIdentifier = "dev.bandito.ios.refresh"
    /// The wish: the next check no sooner than this. The system gives the real interval.
    static let interval: TimeInterval = 15 * 60
    /// The check stops after this long, so the system never has to end the task.
    static let budget: Duration = .seconds(25)

    /// Registers the task handler. Call once, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = BGAppRefreshTaskBox(refresh)
            Task { @MainActor in
                WidgetSnapshotWriter.shared.refreshNow()
                await IOSNotifications.shared.refreshInBackground(box)
            }
        }
    }

    /// Asks the system for the next check. Refused on the Simulator and when the app is not allowed background
    /// refresh: then nothing runs, which is the expected best effort.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// The system's task, passed to the main actor. The system calls its handlers once each, from its own queue.
final class BGAppRefreshTaskBox: @unchecked Sendable {
    private let task: BGAppRefreshTask

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }

    /// Called when the system ends the task early: the work stops at once.
    func onExpire(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    /// Reports the end of the task to the system. Called once.
    func finish(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
