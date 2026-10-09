import Foundation

/// What a terminal's output has been doing, for the sidebar and the dock: line and byte counts, the
/// unfinished last line (to spot a prompt), and a byte histogram for the sparkline.
///
/// Fed with every output chunk of the terminal, also while its pane is collapsed.
public struct TerminalActivity: Sendable {
    /// Width of one sparkline bucket, seconds.
    public static let bucketSeconds: TimeInterval = 5
    /// Buckets in the sparkline: one minute.
    public static let bucketCount = 12
    /// How long the output must stay quiet before a prompt counts as waiting for input, seconds.
    public static let quietSeconds: TimeInterval = 2
    /// The unfinished line is kept this long, characters.
    static let tailLimit = 256

    /// Newline bytes so far.
    public private(set) var lines = 0
    /// Output bytes so far.
    public private(set) var bytes: UInt64 = 0
    public private(set) var lastOutputAt: Date?
    /// The text after the last line break, with escape sequences removed (up to `tailLimit` characters).
    public private(set) var tail = ""
    /// Bytes per bucket, keyed by the bucket index (`time / bucketSeconds`, rounded down).
    private var buckets: [Int64: Int] = [:]

    public init() {}

    public mutating func record(_ data: Data, at time: Date) {
        guard !data.isEmpty else { return }
        bytes += UInt64(data.count)
        lines += data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        lastOutputAt = time

        let text = Self.stripEscapes(String(decoding: data, as: UTF8.self))
        if let cut = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            tail = String(text[text.index(after: cut)...])
        } else {
            tail += text
        }
        if tail.count > Self.tailLimit {
            tail = String(tail.suffix(Self.tailLimit))
        }

        let bucket = Self.bucketIndex(time)
        buckets[bucket, default: 0] += data.count
        buckets = buckets.filter { $0.key > bucket - Int64(Self.bucketCount) }
    }

    /// True when the output has been quiet for `quietSeconds` and the unfinished line ends like a
    /// prompt: `?`, `:` or `]` (which covers `[y/N]`).
    public func isWaitingForInput(now: Date) -> Bool {
        guard let last = lastOutputAt, now.timeIntervalSince(last) > Self.quietSeconds else { return false }
        let line = tail.reversed().drop { $0 == " " || $0 == "\t" }
        guard let end = line.first else { return false }
        return end == "?" || end == ":" || end == "]"
    }

    /// Bytes per bucket for the last minute, oldest first. The last entry is the bucket of `now`.
    public func sparkline(now: Date) -> [Int] {
        let current = Self.bucketIndex(now)
        return (0..<Self.bucketCount).map { offset in
            buckets[current - Int64(Self.bucketCount - 1 - offset)] ?? 0
        }
    }

    private static func bucketIndex(_ time: Date) -> Int64 {
        Int64((time.timeIntervalSince1970 / bucketSeconds).rounded(.down))
    }

    /// Removes CSI sequences (colors, cursor moves) and OSC sequences (titles, links).
    static func stripEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = text.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return result
    }
}
