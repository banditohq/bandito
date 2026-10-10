import Foundation

/// A small memory of values by key: at most `capacity` of them, the least recently used goes first. A failed load is
/// remembered for `failureTTL`, so a broken picture is not asked for again on every redraw. Pure; the clock is the
/// caller's.
struct BoundedCache<Value> {
    let capacity: Int
    let failureTTL: TimeInterval
    private var values: [String: Value] = [:]
    private var lastUsed: [String: UInt64] = [:]
    private var failures: [String: Date] = [:]
    private var tick: UInt64 = 0

    init(capacity: Int, failureTTL: TimeInterval) {
        self.capacity = capacity
        self.failureTTL = failureTTL
    }

    var keys: [String] { Array(values.keys) }

    var count: Int { values.count }

    /// The value for `key`, marking it as used.
    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// Stores a value and evicts the least recently used ones beyond `capacity`.
    mutating func insert(_ value: Value, for key: String) {
        values[key] = value
        failures[key] = nil
        touch(key)
        while values.count > capacity, let oldest = lastUsed.min(by: { $0.value < $1.value })?.key {
            values[oldest] = nil
            lastUsed[oldest] = nil
        }
    }

    /// Whether a load for `key` failed less than `failureTTL` ago.
    func hasFailed(_ key: String, now: Date) -> Bool {
        guard let failedAt = failures[key] else { return false }
        return now.timeIntervalSince(failedAt) < failureTTL
    }

    mutating func recordFailure(for key: String, at now: Date) {
        failures[key] = now
    }

    /// Drops every value and failure whose key `keep` rejects.
    mutating func retain(where keep: (String) -> Bool) {
        for key in values.keys where !keep(key) {
            values[key] = nil
            lastUsed[key] = nil
        }
        for key in failures.keys where !keep(key) {
            failures[key] = nil
        }
    }

    private mutating func touch(_ key: String) {
        tick += 1
        lastUsed[key] = tick
    }
}
