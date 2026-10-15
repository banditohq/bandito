import Foundation

/// Which Apple push service this build's token belongs to: `sandbox` (development) or `production`. The cloud sends to the
/// one it is told, and Apple refuses a token on the other (`docs/IOS_APP.md`, Push).
enum PushEnvironment {
    static let sandbox = "sandbox"
    static let production = "production"

    /// The environment of this build. The Simulator and debug builds are always sandbox. Others read the provisioning
    /// profile inside the app: `development` is sandbox, `production` is production. A build with no profile
    /// (the App Store removes it) is production.
    static func current(bundle: Bundle = .main) -> String {
        #if targetEnvironment(simulator) || DEBUG
        return sandbox
        #else
        let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
        return environment(provision: url.flatMap { try? Data(contentsOf: $0) })
        #endif
    }

    /// The environment a provisioning profile says: its `Entitlements` hold `aps-environment`. The profile is a signed
    /// message with a property list inside; the list is cut out of it. Nil, or a profile that cannot be read, is production.
    static func environment(provision: Data?) -> String {
        guard let provision, let plist = embeddedPlist(in: provision),
            let root = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
            let entitlements = root["Entitlements"] as? [String: Any],
            let aps = entitlements["aps-environment"] as? String
        else { return production }
        return aps == "development" ? sandbox : production
    }

    private static func embeddedPlist(in data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
            start.lowerBound < end.upperBound
        else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}
