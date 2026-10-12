import Foundation

/// Launch arguments for UI tests and screenshots of the connect flow. They exist only in debug builds.
///
///     -openConnect                    opens the connect sheet at launch
///     -pairLink <text>                hands the sheet a link, as if it was opened from outside
///     -pairCamera notAsked|denied|allowed|unavailable   shows that state of the camera permission
enum PairingLaunchHooks {
    #if DEBUG
    static func value(after flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func opensConnect(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("-openConnect") || value(after: "-pairLink", in: arguments) != nil
    }

    static func link(in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        value(after: "-pairLink", in: arguments)
    }

    static func camera(in arguments: [String] = ProcessInfo.processInfo.arguments) -> CameraAccess? {
        switch value(after: "-pairCamera", in: arguments) {
        case "notAsked": .notAsked
        case "denied": .denied
        case "allowed": .allowed
        case "unavailable": .unavailable
        default: nil
        }
    }
    #else
    static func opensConnect(in arguments: [String] = []) -> Bool { false }
    static func link(in arguments: [String] = []) -> String? { nil }
    static func camera(in arguments: [String] = []) -> CameraAccess? { nil }
    #endif
}
