import Foundation

/// Counts the work the chat does, so a test can hold it to a budget (the Mac's `PerfCounters` for the iPhone): cells made
/// ready, rows measured, snapshots applied. Written on the main thread, except `textLayouts`, which the layout engine
/// writes from its own queue (a lock keeps it right). One increment each; kept in every build.
final class ChatCounters: @unchecked Sendable {
    static let shared = ChatCounters()

    private let lock = NSLock()
    private var _cellConfigurations = 0
    private var _configuredRows: [String: Int] = [:]
    private var _textLayouts = 0
    private var _layoutsByRow: [String: Int] = [:]
    private var _snapshots = 0
    private var _reconfigured = 0
    private var _hostedSizes = 0

    /// Cells set up with a row (a new cell, a reused one or a reconfigured one).
    var cellConfigurations: Int { lock.withLock { _cellConfigurations } }
    /// How many times each row's cell was set up.
    var configuredRows: [String: Int] { lock.withLock { _configuredRows } }
    /// Rows measured (parsed and laid out).
    var textLayouts: Int { lock.withLock { _textLayouts } }
    /// How many times each row was measured.
    var layoutsByRow: [String: Int] { lock.withLock { _layoutsByRow } }
    var snapshots: Int { lock.withLock { _snapshots } }
    /// Rows named in `reconfigureItems`.
    var reconfigured: Int { lock.withLock { _reconfigured } }
    var hostedSizes: Int { lock.withLock { _hostedSizes } }

    func cellConfigured(_ id: String) {
        lock.withLock {
            _cellConfigurations += 1
            _configuredRows[id, default: 0] += 1
        }
    }

    func rowMeasured(_ id: String) {
        lock.withLock {
            _textLayouts += 1
            _layoutsByRow[id, default: 0] += 1
        }
    }

    func snapshotApplied(reconfigured count: Int) {
        lock.withLock {
            _snapshots += 1
            _reconfigured += count
        }
    }

    func hostedSized() {
        lock.withLock { _hostedSizes += 1 }
    }

    func reset() {
        lock.withLock {
            _cellConfigurations = 0
            _configuredRows = [:]
            _textLayouts = 0
            _layoutsByRow = [:]
            _snapshots = 0
            _reconfigured = 0
            _hostedSizes = 0
        }
    }
}
