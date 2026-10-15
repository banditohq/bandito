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

    /// The highest event of a server that a push has shown. The background check and the live stream do not make a local
    /// notice for an event up to it.
    func lastSeq(for serverRef: String) -> Int64 {
        Int64(defaults.integer(forKey: Self.seqKey(serverRef)))
    }

    /// Notes that a push showed this event. Only ever moves forward.
    func noteSeq(_ seq: Int64, for serverRef: String) {
        guard seq > lastSeq(for: serverRef) else { return }
        defaults.set(Int(seq), forKey: Self.seqKey(serverRef))
    }

    func forgetSeq(for serverRef: String) {
        defaults.removeObject(forKey: Self.seqKey(serverRef))
    }

    /// `IOSSettings.riskyNeedsFaceID`, copied here for the extension (it cannot read the app's own defaults).
    var riskyNeedsFaceID: Bool {
        get { defaults.object(forKey: Self.riskyKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.riskyKey) }
    }
}
