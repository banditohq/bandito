import Foundation

/// One thing that happens on an attached terminal, in order.
public enum TerminalChunk: Sendable, Equatable {
    case output(Data)
    /// `lost` bytes of output were not delivered (scrollback overflow, a lagging connection, or
    /// too much output held back while an attach was in flight).
    case gap(lost: UInt64)
    /// The program ended. The terminal stays open until it is closed.
    case exit(code: Int?, signal: Int?)
    /// The terminal was closed; the stream ends after this chunk.
    case closed
    /// Re-attaching failed (the message is the daemon's or the transport's). The stream stays open:
    /// the next reconnect attaches again from `nextOffset`.
    case error(FailureKind)
}

/// The output of one attached terminal. Created by `ServerModel.attach(_:from:)`.
///
/// Output is tracked by byte offset: `nextOffset` is the offset just past the last byte delivered.
/// Bytes that were already delivered (overlap after a re-attach) are dropped; a jump forward
/// becomes a `.gap`. Chunks that arrive while an attach is in flight are held back until the snapshot
/// has been applied, so the order always matches the terminal's output.
///
/// Limits: at most `maxHeldBytes` are held back; older held chunks are dropped and the jump shows as a
/// `.gap`. The chunk buffer keeps the newest `chunkBufferLimit` chunks for a consumer that falls behind,
/// so the oldest chunks are lost there without a `.gap`: consume `chunks` promptly.
@MainActor
public final class TerminalStream {
    /// Held-back output while an attach is in flight, in bytes.
    static let maxHeldBytes = 4 << 20
    /// Chunks kept for a slow consumer.
    static let chunkBufferLimit = 1024

    public let id: String
    public let chunks: AsyncStream<TerminalChunk>
    private let continuation: AsyncStream<TerminalChunk>.Continuation

    /// Offset just past the last byte delivered. A re-attach continues from here.
    public private(set) var nextOffset: UInt64 = 0

    /// True until the attach reply has been applied (or the attach failed).
    private var attaching = true
    private var held: [Incoming] = []
    private var heldBytes = 0
    private var finished = false

    /// What the daemon sent for this terminal, held back while `attaching`.
    private enum Incoming {
        case output(offset: UInt64, data: Data)
        case gap(lost: UInt64)
        case exit(code: Int?, signal: Int?)
        case closed

        var byteCount: Int {
            if case .output(_, let data) = self { return data.count }
            return 0
        }
    }

    init(id: String) {
        self.id = id
        (chunks, continuation) = AsyncStream.makeStream(
            of: TerminalChunk.self, bufferingPolicy: .bufferingNewest(Self.chunkBufferLimit))
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
        flushHeld()
    }

    /// The attach failed: stops holding back, delivers what was held, and reports the error.
    /// The stream stays open for the next attach.
    func abortAttach(error: FailureKind) {
        attaching = false
        flushHeld()
        if !finished {
            continuation.yield(.error(error))
        }
    }

    /// The daemon no longer has the terminal: yields `.closed` and ends, whatever the attach state.
    func terminate() {
        guard !finished else { return }
        held = []
        heldBytes = 0
        continuation.yield(.closed)
        finish()
    }

    /// Ends the stream without a `closed` chunk (the caller detached, or the attach failed for good).
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
            hold(item)
        } else {
            apply(item)
        }
    }

    private func hold(_ item: Incoming) {
        held.append(item)
        heldBytes += item.byteCount
        // Drop the oldest output until the cap holds. The jump in offsets shows as a gap on flush.
        while heldBytes > Self.maxHeldBytes, let oldest = held.first {
            held.removeFirst()
            heldBytes -= oldest.byteCount
        }
    }

    private func flushHeld() {
        let pending = held
        held = []
        heldBytes = 0
        for item in pending {
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
