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
}
