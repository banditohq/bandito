import Foundation

/// Keeps the Keychain items of development builds apart from the installed app's.
///
/// Debug builds run as `dev.bandito.mac.debug` and are signed ad hoc. If they used the installed app's
/// items, macOS would ask for the login password on every access (the item trusts only the build that
/// made it), and a test could read or overwrite the owner's session. So every service name of a debug
/// build gets its own prefix.
public enum KeychainNamespace {
    /// `service` for the release app, `dev.bandito.debug.<rest>` for a debug build.
    public static func scoped(_ service: String, bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        guard bundleID?.hasSuffix(".debug") == true, service.hasPrefix("dev.bandito.") else { return service }
        return "dev.bandito.debug." + service.dropFirst("dev.bandito.".count)
    }

    /// Whether this process is a debug build of the app.
    public static func isDebugBuild(bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleID?.hasSuffix(".debug") == true
    }

    /// For a debug build: secrets go to `~/Library/Application Support/Bandito Debug/secrets/<service>`,
    /// never to the Keychain. Nil for the release app and for tests.
    public static func debugFileStore(service: String, bundleID: String? = Bundle.main.bundleIdentifier) -> FileSecretStore? {
        guard isDebugBuild(bundleID: bundleID) else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return FileSecretStore(directory: base.appending(path: "Bandito Debug/secrets/\(service)"))
    }
}
