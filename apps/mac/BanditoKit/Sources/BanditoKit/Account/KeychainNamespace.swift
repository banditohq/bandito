import Foundation

/// Keeps the Keychain items of development builds apart from the installed app's.
///
/// Debug builds run as `dev.bandito.mac.debug` and are signed ad hoc. If they used the installed app's
/// items, macOS would ask for the login password on every access (the item trusts only the build that
/// made it), and a test could read or overwrite the owner's session. So every service name of a debug
/// build gets its own prefix. A QA copy (`QABuild`) gets its own prefix too, `dev.bandito.debug.qa<n>.<rest>`.
public enum KeychainNamespace {
    /// `service` for the release app, `dev.bandito.debug.<rest>` for a debug build, `dev.bandito.debug.qa<n>.<rest>`
    /// for a QA copy.
    public static func scoped(_ service: String, bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        guard let infix = debugInfix(bundleID: bundleID), service.hasPrefix("dev.bandito.") else { return service }
        return "dev.bandito.debug" + infix + "." + service.dropFirst("dev.bandito.".count)
    }

    /// Whether this process is a debug build of the app (a QA copy counts).
    public static func isDebugBuild(bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        debugInfix(bundleID: bundleID) != nil
    }

    /// The part that tells debug builds apart: "" for `dev.bandito.mac.debug`, ".qa<n>" for a QA copy, nil otherwise.
    private static func debugInfix(bundleID: String?) -> String? {
        if bundleID?.hasSuffix(".debug") == true { return "" }
        if let index = QABuild.index(bundleID: bundleID) { return ".qa\(index)" }
        return nil
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
