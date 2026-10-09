import Foundation

/// One thing that happens on an attached terminal, in order.
public enum TerminalChunk: Sendable, Equatable {
    case output(Data)
    /// `lost` bytes of output were not delivered (scrollback overflow, or the connection lagged).
    case gap(lost: UInt64)
    /// The program ended. The terminal stays open until it is closed.
    case exit(code: Int?, signal: Int?)
    /// The terminal was closed; the stream ends after this chunk.
    case closed
}

/// The output of one attached terminal. Created by `ServerModel.attach(_:from:)`.
///
/// Output is tracked by byte offset: `nextOffset` is the offset just past the last byte delivered.
/// Bytes that were already delivered (overlap after a re-attach) are dropped; a jump forward
/// becomes a `.gap`. Chunks that arrive while the attach call is still in flight are held back
/// until the snapshot has been applied, so the order always matches the terminal's output.
@MainActor
public final class TerminalStream {
    public let id: String
    public let chunks: AsyncStream<TerminalChunk>
    private let continuation: AsyncStream<TerminalChunk>.Continuation

    /// Offset just past the last byte delivered. A re-attach continues from here.
    public private(set) var nextOffset: UInt64 = 0

    /// True until the attach reply has been applied.
    private var attaching = true
    private var held: [Incoming] = []
    private var finished = false

    /// What the daemon sent for this terminal, held back while `attaching`.
    private enum Incoming {
        case output(offset: UInt64, data: Data)
        case gap(lost: UInt64)
        case exit(code: Int?, signal: Int?)
        case closed
    }

    init(id: String) {
        self.id = id
        (chunks, continuation) = AsyncStream.makeStream(of: TerminalChunk.self, bufferingPolicy: .unbounded)
    }

    // MARK: attach lifecycle (driven by ServerModel)

    /// Called before `term.attach` is sent: from now on, notifications are held back.
    func beginAttach() {
        attaching = true
    }

    /// Called with the `term.attach` reply. `from` is what the caller asked for (nil: from the oldest byte kept).
    func completeAttach(from: UInt64?, start: UInt64, data: Data) {
        nextOffset = from ?? start
        attaching = false
        deliver(offset: start, data: data)
        let pending = held
        held = []
        for item in pending {
            apply(item)
        }
    }

    /// The daemon no longer has the terminal: yields `.closed` and ends, whatever the attach state.
    func terminate() {
        guard !finished else { return }
        continuation.yield(.closed)
        finish()
    }

    /// Ends the stream without a `closed` chunk (the caller detached, or the attach failed).
    func finish() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    // MARK: notifications (driven by ServerModel)

    func receiveOutput(offset: UInt64, data: Data) {
        receive(.output(offset: offset, data: data))
    }

    func receiveGap(lost: UInt64) {
        receive(.gap(lost: lost))
    }

    func receiveExit(code: Int?, signal: Int?) {
        receive(.exit(code: code, signal: signal))
    }

    func receiveClosed() {
        receive(.closed)
    }

    private func receive(_ item: Incoming) {
        guard !finished else { return }
        if attaching {
            held.append(item)
        } else {
            apply(item)
        }
    }

    private func apply(_ item: Incoming) {
        switch item {
        case .output(let offset, let data):
            deliver(offset: offset, data: data)
        case .gap(let lost):
            nextOffset += lost
            continuation.yield(.gap(lost: lost))
        case .exit(let code, let signal):
            continuation.yield(.exit(code: code, signal: signal))
        case .closed:
            continuation.yield(.closed)
            finish()
        }
    }

    /// Yields the part of `data` that is not delivered yet, after a gap if there is one.
    private func deliver(offset: UInt64, data: Data) {
        var offset = offset
        var data = data
        if offset < nextOffset {
            let overlap = nextOffset - offset
            guard overlap < UInt64(data.count) else { return }
            data = Data(data.dropFirst(Int(overlap)))
            offset = nextOffset
        }
        if offset > nextOffset {
            continuation.yield(.gap(lost: offset - nextOffset))
            nextOffset = offset
        }
        guard !data.isEmpty else { return }
        continuation.yield(.output(data))
        nextOffset += UInt64(data.count)
    }
}
