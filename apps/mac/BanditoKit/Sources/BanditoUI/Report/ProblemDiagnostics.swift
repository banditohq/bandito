import BanditoKit
import Foundation
import OSLog
import SystemConfiguration

/// What a problem report may say about this Mac and its servers: versions, how each server is connected, and the last
/// lines of the app's log and the daemon's log. Chats, server names and addresses are never read here; whatever a log
/// line carries goes through `SecretRedactor` as well (`text(redactor:)`).
struct ProblemDiagnostics: Sendable, Equatable {
    /// The lines of `ServerSupportReport` (versions, systems, features).
    var versions: String
    var servers: [ServerLine]
    var appLog: [String]
    var daemonLog: [String]
    /// Why the daemon's log is missing, when it is: an older daemon, no connection.
    var daemonLogNote: String?
    /// Why the app's log is missing, when it is: it could not be read in time.
    var appLogNote: String?

    /// One server as "This Mac" or "Linux server 2", with how it is connected. No name and no address.
    struct ServerLine: Sendable, Equatable {
        var label: String
        var state: String
    }

    /// The most lines taken from each log.
    static let logLines = 200
    /// A line is cut here: a long message is one chat's text more often than a fact.
    static let lineLimit = 300

    // MARK: text

    /// The diagnostics as the report shows them, every line redacted.
    func text(redactor: SecretRedactor) -> String {
        var out: [String] = [versions, "", "Servers:"]
        out += servers.isEmpty ? ["- none"] : servers.map { "- \($0.label): \($0.state)" }
        out += ["", "App log (last \(appLog.count) lines):", "```"]
        out += appLog.isEmpty ? [appLogNote ?? "(empty)"] : appLog.map { Self.line($0, redactor) }
        out += ["```", "", "Daemon log (last \(daemonLog.count) lines):", "```"]
        if daemonLog.isEmpty {
            out.append(daemonLogNote ?? "(empty)")
        } else {
            out += daemonLog.map { Self.line($0, redactor) }
        }
        out.append("```")
        return redactor.redact(out.joined(separator: "\n"))
    }

    private static func line(_ raw: String, _ redactor: SecretRedactor) -> String {
        // Hidden first, then cut: a key cut in half would be too short for the rule that knows it.
        let flat = redactor.redact(
            raw.replacingOccurrences(of: "```", with: "'''").trimmingCharacters(in: .whitespacesAndNewlines))
        return flat.count > lineLimit ? String(flat.prefix(lineLimit)) + "…" : flat
    }

    // MARK: servers

    /// The way a connection is told in a report.
    static func stateWords(_ state: ConnectionState, disabled: Bool) -> String {
        if disabled { return "switched off" }
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting(let attempt): return "reconnecting (attempt \(attempt))"
        case .failed(let kind): return "failed (\(String(describing: kind)))"
        }
    }

    /// The server lines in the order of the list: "This Mac", then "Linux server 1", "Linux server 2"… A server whose
    /// system is not known yet is "Server N".
    static func serverLines(
        _ servers: [(isThisMac: Bool, os: String?, state: ConnectionState, disabled: Bool)]
    ) -> [ServerLine] {
        var remote = 0
        return servers.map { server in
            let label: String
            if server.isThisMac {
                label = "This Mac"
            } else {
                remote += 1
                label = server.os.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) server \(remote)" } ?? "Server \(remote)"
            }
            return ServerLine(label: label, state: stateWords(server.state, disabled: server.disabled))
        }
    }
}

// MARK: collecting

/// Reads the facts for a report. The app's log is read off the main thread.
enum ProblemDiagnosticsCollector {
    private static let subsystem = "dev.bandito"

    @MainActor
    static func collect(app: AppModel) async -> (diagnostics: ProblemDiagnostics, terms: [String]) {
        let current = app.currentServer
        let versions = ServerSupportReport.make(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOS: macOSVersion, macArchitecture: architecture, daemon: current?.info, host: nil
        ).text
        let lines = ProblemDiagnostics.serverLines(
            app.servers.map {
                (isThisMac: $0.config.isThisMac, os: $0.info?.os, state: $0.state, disabled: $0.config.disabled)
            })
        var daemonLog: [String] = []
        var note: String?
        if let current {
            if current.supports("logs") {
                if let lines = await race(timeout) { try? await current.daemonLog(lines: ProblemDiagnostics.logLines).lines } {
                    daemonLog = lines
                } else {
                    note = "(the daemon's log could not be read in time)"
                }
            } else {
                note = "(this daemon has no log method)"
            }
        } else {
            note = "(no server)"
        }
        let appLog = await readAppLog()
        return (
            ProblemDiagnostics(
                versions: versions, servers: lines, appLog: appLog ?? [], daemonLog: daemonLog, daemonLogNote: note,
                appLogNote: appLog == nil ? "(the app's log could not be read in time)" : nil),
            terms(app: app)
        )
    }

    /// How long the report waits for a log: the system's log store can take several seconds to open.
    static let timeout: Duration = .seconds(8)

    /// The app's log lines, or nil when the store did not answer in `timeout`. The read goes on in the background
    /// after that and its answer is dropped.
    private static func readAppLog() async -> [String]? {
        await race(timeout) {
            await Task.detached(priority: .userInitiated) { appLogLines(limit: ProblemDiagnostics.logLines) }.value
        }
    }

    /// The answer of `work`, or nil when it gives none (or none in `timeout`: a log that does not come must not hold
    /// the report). Cancelling is not possible for the system's log store, so the late answer is dropped.
    private static func race<T: Sendable>(
        _ timeout: Duration, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = OnceGate<T?>(continuation)
            Task { gate.finish(await work()) }
            Task {
                try? await Task.sleep(for: timeout)
                gate.finish(nil)
            }
        }
    }

    /// Resumes a continuation with the first answer; a later one is dropped.
    private final class OnceGate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: Value) {
            let taken = lock.withLock { () -> CheckedContinuation<Value, Never>? in
                defer { continuation = nil }
                return continuation
            }
            taken?.resume(returning: value)
        }
    }

    /// Words of this Mac and its servers that the redactor hides wherever they appear.
    @MainActor
    static func terms(app: AppModel) -> [String] {
        var out = [NSUserName(), NSFullUserName(), NSHomeDirectory(), localHostName()]
        // The computer's name as System Settings shows it. `Host.current()` and `ProcessInfo.hostName` look the name up
        // on the network: that blocks for seconds without one, and asks the person for the local network.
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { out.append(name) }
        for server in app.servers {
            if !server.config.isThisMac { out.append(server.config.name) }
            if let hostname = server.info?.hostname { out.append(hostname) }
            switch server.config.endpoint {
            case .ssh(let address, _):
                out.append(address.host)
                if let user = address.user { out.append(user) }
            case .webSocket(let url):
                if let host = url.host() { out.append(host) }
            case .direct(let hosts, _):
                out.append(contentsOf: hosts)
            case .reachable(let hosts, _, _, _):
                out.append(contentsOf: hosts)
            case .local:
                break
            }
        }
        return Array(Set(out.filter { !$0.isEmpty }))
    }

    /// The host name from the system call, with no lookup.
    nonisolated private static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(cString: buffer)
    }

    private static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The last `limit` lines the app wrote to its log in the last hour (subsystem `dev.bandito`), oldest first.
    /// Debug lines are left out. Empty when the log cannot be read.
    nonisolated static func appLogLines(limit: Int, since: TimeInterval = 3600) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: Date().addingTimeInterval(-since))
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            let level: String
            switch entry.level {
            case .debug: continue
            case .info: level = "info"
            case .notice: level = "notice"
            case .error: level = "error"
            case .fault: level = "fault"
            default: level = "log"
            }
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(level): \(entry.composedMessage)")
        }
        return Array(lines.suffix(limit))
    }
}
