import Foundation

/// The "Read replies aloud" switch of an agent. Kept on this Mac in UserDefaults, one key per agent id; off by default.
public enum ReadAloud {
    public static func isOn(agentID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(agentID))
    }

    public static func set(_ on: Bool, agentID: String, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key(agentID))
    }

    static func key(_ agentID: String) -> String {
        "readAloud.\(agentID)"
    }
}
