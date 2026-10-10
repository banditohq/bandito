import Foundation

/// Keeps the daemon on this Mac at the version of the app that runs it: when the app bundle carries a newer daemon
/// than the installed service, the service is updated, the way Docker Desktop or Tailscale update theirs. These are
/// the pure rules. The copy and the restart are `LocalInstaller.upgrade()`.
public enum LocalDaemonUpgrade {
    /// Whether this Mac's daemon should be replaced by the bundled one. Never a downgrade. Never for a QA copy.
    /// Both versions must parse as `SemanticVersion`; a missing or unreadable version means no upgrade.
    public static func decide(serverVersion: String?, bundledVersion: String?, isLocalServer: Bool, isQA: Bool) -> Bool {
        guard !isQA, isLocalServer,
            let serverVersion, let installed = SemanticVersion(serverVersion),
            let bundledVersion, let bundled = SemanticVersion(bundledVersion)
        else { return false }
        return bundled > installed
    }

    /// What the Updates page says about this Mac's daemon. `checking` until the bundle has been read; `unknown` when a
    /// version is missing or does not parse, which must not read as "up to date".
    public static func standing(
        bundleRead: Bool, bundledVersion: String?, serverVersion: String?, isLocalServer: Bool, isQA: Bool
    ) -> LocalUpgradeStanding {
        guard bundleRead else { return .checking }
        guard let bundledVersion, SemanticVersion(bundledVersion) != nil,
            let serverVersion, SemanticVersion(serverVersion) != nil
        else { return .unknown }
        return decide(
            serverVersion: serverVersion, bundledVersion: bundledVersion, isLocalServer: isLocalServer, isQA: isQA)
            ? .due(bundled: bundledVersion) : .upToDate
    }

    /// The version in the answer of `bandito --version` (`bandito 0.1.2\n` → `0.1.2`). Nil for any other answer.
    public static func parseVersion(_ output: String) -> String? {
        let parts = output.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0] == "bandito", SemanticVersion(String(parts[1])) != nil else { return nil }
        return String(parts[1])
    }

    /// Whether a saved server is this Mac's daemon: the unix socket, or a server the flag marks (`ServerConfig.isThisMac`).
    /// A loopback address alone is not enough: any program can listen there.
    public static func isThisMac(_ config: ServerConfig) -> Bool {
        if case .local = config.endpoint { return true }
        return config.isThisMac
    }

    /// The installed daemon: `~/.local/bin/bandito`.
    public static func installedBinary(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appending(path: ".local/bin/bandito")
    }

    /// Whether an existing server without the flag is this Mac's daemon. All of these must hold: the server is a
    /// WebSocket on loopback, the installed binary exists, and `bandito info --json` reports `running: true` on the
    /// port the address names. The answer comes within `timeout`: a daemon CLI that hangs counts as "not this Mac",
    /// and its process is stopped. Nothing is changed here; the caller stores the flag when this is true.
    public static func confirmsThisMac(
        _ config: ServerConfig, binary: URL, runner: CommandRunner, timeout: Duration = .seconds(3)
    ) async -> Bool {
        guard case .webSocket(let url) = config.endpoint, isLoopback(url), let port = url.port,
            FileManager.default.fileExists(atPath: binary.path)
        else { return false }
        return await firstAnswer(within: timeout, fallback: false) {
            guard let result = try? await runner.run(binary.path, ["info", "--json"], stdin: nil),
                result.status == 0,
                let info = try? JSONDecoder().decode(RunningInfo.self, from: Data(result.stdout.utf8)),
                info.running
            else { return false }
            return SSHInstaller.listenPort(in: result.stdout) == port
        }
    }

    /// The part of `info --json` that says whether the daemon runs.
    private struct RunningInfo: Decodable {
        var running: Bool
    }

    /// The answer of `work`, or `fallback` when `limit` runs out first. Then `work` is cancelled. A task group is not
    /// used: it would wait for a `work` that ignores cancellation, and the limit would not hold.
    static func firstAnswer(
        within limit: Duration, fallback: Bool, work: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceAnswer(continuation)
            let job = Task {
                once.finish(await work())
            }
            Task {
                try? await Task.sleep(for: limit)
                once.finish(fallback)
                job.cancel()
            }
        }
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "ws" || url.scheme?.lowercased() == "wss" else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains(
            (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }
}

/// What the Updates page says about this Mac's daemon (see `LocalDaemonUpgrade.standing`).
public enum LocalUpgradeStanding: Equatable, Sendable {
    case checking
    case unknown
    case upToDate
    /// The app bundle carries a newer daemon with this version.
    case due(bundled: String)
}

/// What the upgrade of this Mac's daemon needs from the installer. `LocalInstaller` conforms; tests pass a fake.
public protocol DaemonReplacing: Sendable {
    /// The version of the daemon in the app bundle, or nil.
    func bundledVersion() async -> String?
    /// Replaces the installed daemon and restarts its service. See `LocalInstaller.upgrade`.
    func upgrade() async throws
}

extension LocalInstaller: DaemonReplacing {}

/// Resumes a continuation once: the first answer wins, the others are dropped.
private final class OnceAnswer: @unchecked Sendable {
    // @unchecked: `continuation` is taken under `lock`, once.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ answer: Bool) {
        let taken = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: answer)
    }
}
