import AppKit
import BanditoKit
import Observation

/// Keeps the Dock icon's badge at the unread replies of the connected servers (`DockBadgeRules`). It reads each
/// agent's count (`AgentThreadState.unreadCount`), which changes only with a new reply or a read, never with a streamed
/// token. The icon is written only when the label changes.
@MainActor
final class DockBadge {
    private let app: AppModel
    private let defaults: UserDefaults
    private let write: (String?) -> Void
    private var total = 0
    private var shown: String?
    private var defaultsObserver: NSObjectProtocol?

    init(
        app: AppModel, defaults: UserDefaults = .standard,
        write: @escaping (String?) -> Void = { NSApplication.shared.dockTile.badgeLabel = $0 }
    ) {
        self.app = app
        self.defaults = defaults
        self.write = write
    }

    /// Starts watching: the counts, the servers and their connections, and the switch in the settings.
    func start() {
        track()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    /// Reads the total and watches what it read: a change of any of it reads the total again.
    private func track() {
        total = withObservationTracking {
            DockBadgeRules.total(
                app.servers.filter { $0.state == .connected }.flatMap { server in
                    server.agents.map { server.threadSummary(for: $0.id).unreadCount }
                })
        } onChange: {
            Task { @MainActor [weak self] in self?.track() }
        }
        publish()
    }

    private func publish() {
        let label = DockBadgeRules.label(total: total, enabled: DockBadgeRules.isOn(defaults))
        guard label != shown else { return }
        shown = label
        write(label)
    }
}
