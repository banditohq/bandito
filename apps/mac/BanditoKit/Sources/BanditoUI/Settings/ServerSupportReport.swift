import BanditoKit
import Foundation

/// The text a person copies for support: the versions, the systems and the features. It is built from these fields
/// only, so a server address, a host name, a token, the socket path or a folder of the person's home cannot get into
/// it: `make` takes no such value. The labels stay in English, because the report is read by whoever helps.
struct ServerSupportReport: Equatable {
    var appVersion: String
    var appBuild: String
    var macOS: String
    var macArchitecture: String
    var daemonVersion: String?
    var serverSystem: String?
    var serverArchitecture: String?
    var serverKernel: String?
    var safeMode: Bool
    /// Sorted, so the same server gives the same text.
    var features: [String]

    /// Builds the report from what the app and the server already know. `host` is the last `host.stats` (nil when
    /// the server has no host feature or has not answered).
    static func make(
        appVersion: String, appBuild: String, macOS: String, macArchitecture: String,
        daemon: DaemonInfo?, host: HostStats?
    ) -> ServerSupportReport {
        ServerSupportReport(
            appVersion: appVersion,
            appBuild: appBuild,
            macOS: macOS,
            macArchitecture: macArchitecture,
            daemonVersion: daemon?.version,
            serverSystem: daemon?.os,
            serverArchitecture: daemon?.arch,
            serverKernel: host?.kernel,
            safeMode: daemon?.isSafeMode ?? false,
            features: (daemon?.features ?? []).sorted())
    }

    /// The lines of the report, one fact each. A missing value reads "unknown", so a gap is visible to support.
    var text: String {
        [
            "Bandito for Mac: \(appVersion) (build \(appBuild))",
            "Mac: macOS \(macOS), \(macArchitecture)",
            "Daemon: \(daemonVersion ?? "unknown")",
            "Server system: \(Self.joined(serverSystem, serverArchitecture)), kernel \(serverKernel ?? "unknown")",
            "Safe mode: \(safeMode ? "yes" : "no")",
            "Features: \(features.isEmpty ? "none" : features.joined(separator: ", "))",
        ].joined(separator: "\n")
    }

    private static func joined(_ first: String?, _ second: String?) -> String {
        let parts = [first, second].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "unknown" : parts.joined(separator: " ")
    }
}
