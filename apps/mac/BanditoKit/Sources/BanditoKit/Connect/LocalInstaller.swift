import CryptoKit
import Foundation

/// Puts Bandito on this Mac: copies the bandito binary from the app bundle into `~/.local/bin` when it is missing
/// or different (SHA-256), runs `service install --json`, waits until the daemon answers `running: true`, and pairs
/// the app with it: the daemon's WebSocket on loopback gives the app a device token, like any other server
/// (docs/ARCHITECTURE.md#transports). The server is never a unix socket: that socket is the owner's CLI channel only.
public struct LocalInstaller: Sendable {
    /// How many lines of the daemon's log go to the install log when the daemon does not start.
    static let logTailLines = 20

    private let runner: CommandRunner
    private let bundledBinary: URL?
    private let home: URL
    private let hostName: String?
    private let fallbackName: String
    private let pairing: LocalDaemonPairing
    private let binary: URL
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private let qaBuild: Bool

    /// Where the app bundle keeps the daemon: `Contents/Helpers/bandito`. Helpers, not MacOS: on a
    /// case-insensitive volume `MacOS/bandito` would be the app's own `Bandito` executable.
    public static func bundledDaemonURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appending(path: "Contents/Helpers/bandito")
    }

    /// - Parameters:
    ///   - runner: runs the installed binary.
    ///   - bundledBinary: the bandito binary inside the app bundle. Default: `Contents/Helpers/bandito`.
    ///   - home: the user's home directory (a test passes a temporary one).
    ///   - hostName: this Mac's name (`Host.current().localizedName`). Nil or empty uses `fallbackName`.
    ///   - fallbackName: the server's name when this Mac has no name. The caller passes the localized "This Mac".
    ///   - redeem: exchanges the pairing code for a token. Default: over the WebSocket on loopback.
    ///   - pollInterval: how long to wait between two `info --json` asks while the daemon starts.
    ///   - pollTimeout: how long the daemon may take to answer `running: true` before the install fails.
    ///   - qaBuild: a QA copy of the app (`QABuild`). It never installs: the owner's CLI and service stay untouched.
    public init(
        runner: CommandRunner,
        bundledBinary: URL? = LocalInstaller.bundledDaemonURL(),
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        hostName: String?,
        fallbackName: String,
        redeem: LocalDaemonPairing.Redeem? = nil,
        pollInterval: Duration = .milliseconds(500),
        pollTimeout: Duration = .seconds(20),
        qaBuild: Bool = QABuild.isRunningQA
    ) {
        self.runner = runner
        self.bundledBinary = bundledBinary
        self.home = home
        self.hostName = hostName
        self.fallbackName = fallbackName
        self.qaBuild = qaBuild
        self.binary = home.appending(path: ".local/bin/bandito")
        self.pairing = LocalDaemonPairing(runner: runner, binary: binary, redeem: redeem)
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
    }

    /// Installs and starts the service, then pairs the app. The stream ends with `.done` or `.failed`.
    public func install() -> AsyncStream<InstallEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: InstallEvent.self)
        let task = Task {
            await run { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The server's name: this Mac's name, or the fallback when there is none.
    var serverName: String {
        let name = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallbackName : name
    }

    /// Replaces the installed daemon with the one in the app bundle, when the content differs. The service is restarted
    /// with `service install --json` (launchd replaces the running daemon), and the call returns once the daemon answers.
    /// No pairing: the daemon stays the same, so the device tokens stay valid. Throws `InstallError`. An upgrade never
    /// installs from scratch: without an installed daemon it throws `localBinaryMissing` and changes nothing. A QA copy
    /// never upgrades either.
    public func upgrade() async throws {
        guard !qaBuild else { throw InstallError.io("QA builds do not install Bandito on this Mac.") }
        guard FileManager.default.fileExists(atPath: binary.path) else { throw InstallError.localBinaryMissing }
        try installBinary(emit: { _ in })
        _ = try await startService(emit: { _ in })
    }

    /// The version of the daemon in the app bundle, read once per binary for the life of the process (`--version`).
    /// Nil when the bundle has no daemon or the answer has no version. A nil answer is asked again next time.
    public func bundledVersion() async -> String? {
        guard let bundledBinary else { return nil }
        return await BundledVersionCache.shared.version(of: bundledBinary) {
            guard let result = try? await self.runner.run(bundledBinary.path, ["--version"], stdin: nil),
                result.status == 0
            else { return nil }
            return LocalDaemonUpgrade.parseVersion(result.stdout)
        }
    }

    private func run(emit: (InstallEvent) -> Void) async {
        // Checked before anything is copied or started: a QA copy must not touch the owner's ~/.local/bin or service.
        if qaBuild {
            emit(.failed(.io("QA builds do not install Bandito on this Mac.")))
            return
        }
        do {
            emit(.step(.install, "Installing Bandito on this Mac"))
            let existed = try installBinary(emit: emit)

            emit(.step(.service, "Starting the service"))
            let service = try await startService(emit: emit)

            emit(.step(.pair, "Pairing the app"))
            let paired = try await pairing.pair(name: serverName, deviceName: serverName)
            emit(
                .done(
                    PairInfo(server: paired.config, alreadyInstalled: existed, warnings: service.warnings ?? [])))
        } catch let error as InstallError {
            emit(.failed(error))
        } catch {
            emit(.failed(.io(error.localizedDescription)))
        }
    }

    /// Copies the bundled daemon over `~/.local/bin/bandito` when it is missing or has different content (SHA-256).
    /// Returns whether a binary was installed before this call. Throws `localBinaryMissing` when there is nothing to copy.
    @discardableResult
    private func installBinary(emit: (InstallEvent) -> Void) throws -> Bool {
        let existed = FileManager.default.fileExists(atPath: binary.path)
        if let bundledBinary {
            guard FileManager.default.fileExists(atPath: bundledBinary.path) else {
                throw InstallError.localBinaryMissing
            }
            if try !existed || Self.digest(of: bundledBinary) != Self.digest(of: binary) {
                try Self.replace(binary, withCopyOf: bundledBinary)
                emit(.log("Copied bandito to \(binary.path)"))
            }
        } else if !existed {
            throw InstallError.localBinaryMissing
        }
        return existed
    }

    /// Runs `service install --json`, then waits until the daemon answers. Returns the service's answer.
    private func startService(emit: (InstallEvent) -> Void) async throws -> SSHInstaller.ServiceReply {
        let result = try await runner.run(binary.path, ["service", "install", "--json"], stdin: nil)
        let service = try SSHInstaller.serviceOutcome(result)
        try await waitForDaemon(emit: emit)
        return service
    }

    /// Asks `info --json` until the daemon reports `running: true`. A daemon that is still starting is asked again.
    /// When the time is up, the last lines of its log go to the install log, and the install fails.
    private func waitForDaemon(emit: (InstallEvent) -> Void) async throws {
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while true {
            if try await daemonRunning() { return }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pollInterval)
        }
        let tail = daemonLogTail()
        if !tail.isEmpty {
            emit(.log("Last lines of \(daemonLog.path):"))
            for line in tail {
                emit(.log(line))
            }
        }
        throw InstallError.localDaemonNotStarted
    }

    /// One `info --json` ask. A call that fails or answers something else counts as "not running yet".
    private func daemonRunning() async throws -> Bool {
        struct Reply: Decodable { var running: Bool }
        let result = try await runner.run(binary.path, ["info", "--json"], stdin: nil)
        guard result.status == 0, let reply = try? JSONDecoder().decode(Reply.self, from: Data(result.stdout.utf8))
        else { return false }
        return reply.running
    }

    /// The daemon's log of this user: `~/.bandito/logs/daemon.log`.
    private var daemonLog: URL {
        home.appending(path: ".bandito/logs/daemon.log")
    }

    private func daemonLogTail() -> [String] {
        guard let text = try? String(contentsOf: daemonLog, encoding: .utf8) else { return [] }
        return Array(SSHInstaller.lines(text).suffix(Self.logTailLines))
    }

    static func digest(of url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Copies `source` to a temporary file next to `destination`, makes it executable, and renames it over
    /// `destination`. The rename is atomic: a reader sees the old binary or the new one, never a partial copy.
    static func replace(_ destination: URL, withCopyOf source: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else {
                throw InstallError.io("could not replace \(destination.path)")
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

/// The bundled daemon's version per binary path, kept for the life of the process. Only answers with a version are
/// kept: a failed read is asked again the next time.
actor BundledVersionCache {
    static let shared = BundledVersionCache()

    private var versions: [String: String] = [:]

    func version(of binary: URL, read: @Sendable () async -> String?) async -> String? {
        if let known = versions[binary.path] { return known }
        guard let version = await read() else { return nil }
        versions[binary.path] = version
        return version
    }
}
