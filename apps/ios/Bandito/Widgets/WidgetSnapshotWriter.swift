import BanditoKit
import Foundation
import Observation
import WidgetKit

// Keeps the widgets' snapshot current. A change of the Inbox or the crew schedules a write, at most one a second; the
// write happens only when the picture differs from the last one written, and then the widgets reload. The widget
// extension only reads the file: no network, no shared state beyond it.

@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter(
        store: WidgetSnapshotStore.appGroup(),
        reload: { WidgetCenter.shared.reloadAllTimelines() })

    /// The most a change waits before it is written: the changes of that second are written once.
    static let delay: Duration = .seconds(1)

    private let store: WidgetSnapshotStore?
    private let reload: @MainActor () -> Void
    /// The last picture written, or read from the file at start.
    private(set) var written: WidgetSnapshot?
    private var scheduled: Task<Void, Never>?
    private var source: (@MainActor () -> [ServerModel])?
    /// Told every picture the writer builds, each time it is built (a change of the servers, after the one-second delay).
    /// The Spotlight index follows the directory and changes only what differs; it is called with or without a store.
    var onPicture: (@MainActor (WidgetSnapshot) -> Void)?

    init(store: WidgetSnapshotStore?, reload: @escaping @MainActor () -> Void) {
        self.store = store
        self.reload = reload
        written = store?.read()
    }

    /// Starts watching the servers once: every change the Inbox or the crew reads schedules a write.
    func watch(_ servers: @escaping @MainActor () -> [ServerModel]) {
        guard source == nil else { return }
        source = servers
        changed()
        observe()
    }

    /// Writes the picture now (a background refresh): a write that is scheduled is dropped.
    func refreshNow() {
        scheduled?.cancel()
        scheduled = nil
        commit()
    }

    /// Writes `snapshot` when its content differs from the last one written, then reloads the widgets. Returns whether it
    /// wrote: nothing is written when the content is the same (the time of writing does not count), or without a store.
    @discardableResult
    func commitIfChanged(_ snapshot: WidgetSnapshot) -> Bool {
        if let written, written.hasSameContent(as: snapshot) { return false }
        guard let store else { return false }
        do {
            try store.write(snapshot)
        } catch {
            return false
        }
        written = snapshot
        reload()
        return true
    }

    /// Schedules the write of the picture one `delay` from now, unless one is already scheduled.
    private func changed() {
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            self.commit()
        }
    }

    private func commit() {
        guard let source else { return }
        let snapshot = WidgetSnapshotBuilder.make(servers: source())
        onPicture?(snapshot)
        commitIfChanged(snapshot)
    }

    /// Reads what the snapshot reads, so Observation calls back on the next change; then schedules a write and re-arms.
    private func observe() {
        guard let read = source else { return }
        withObservationTracking {
            _ = WidgetSnapshotBuilder.make(servers: read())
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.changed()
                self?.observe()
            }
        }
    }
}
