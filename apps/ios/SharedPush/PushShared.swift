import Foundation

/// The plain values the app and the extension share, in the App Group's UserDefaults.
struct PushShared: @unchecked Sendable {
    // @unchecked: UserDefaults is thread safe.
    static let shared = PushShared(defaults: UserDefaults(suiteName: PushGroup.identifier) ?? .standard)

    static let riskyKey = "push.riskyNeedsFaceID"

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func seqKey(_ serverRef: String) -> String { "push.seq.\(serverRef)" }
    static func seenKey(_ serverRef: String) -> String { "push.seen.\(serverRef)" }
    /// How many of the latest events a push showed are remembered per server.
    static let seenLimit = 200

    /// The highest event of a server that a push has shown (`push.seq.<serverRef>`).
    func lastSeq(for serverRef: String) -> Int64 {
        Int64(defaults.integer(forKey: Self.seqKey(serverRef)))
    }

    /// Notes that a push showed this event: it joins the latest `seenLimit` (a ring), and the highest one moves forward.
    func noteSeq(_ seq: Int64, for serverRef: String) {
        var seen = (defaults.array(forKey: Self.seenKey(serverRef)) as? [Int]) ?? []
        if !seen.contains(Int(seq)) {
            seen.append(Int(seq))
            if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
            defaults.set(seen, forKey: Self.seenKey(serverRef))
        }
        if seq > lastSeq(for: serverRef) { defaults.set(Int(seq), forKey: Self.seqKey(serverRef)) }
    }

    /// Whether a push showed exactly this event. A local notice is held back only for such an event: a lower number that no
    /// push showed (the daemon dropped it) still gets its notice.
    func hasSeen(_ seq: Int64, for serverRef: String) -> Bool {
        ((defaults.array(forKey: Self.seenKey(serverRef)) as? [Int]) ?? []).contains(Int(seq))
    }

    func forgetSeq(for serverRef: String) {
        defaults.removeObject(forKey: Self.seqKey(serverRef))
        defaults.removeObject(forKey: Self.seenKey(serverRef))
    }

    /// `IOSSettings.riskyNeedsFaceID`, copied here for the extension (it cannot read the app's own defaults).
    var riskyNeedsFaceID: Bool {
        get { defaults.object(forKey: Self.riskyKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.riskyKey) }
    }
}
