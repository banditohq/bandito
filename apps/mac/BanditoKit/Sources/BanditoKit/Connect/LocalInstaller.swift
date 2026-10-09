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

    private func run(emit: (InstallEvent) -> Void) async {
        // Checked before anything is copied or started: a QA copy must not touch the owner's ~/.local/bin or service.
        if qaBuild {
            emit(.failed(.io("QA builds do not install Bandito on this Mac.")))
            return
        }
        let existed = FileManager.default.fileExists(atPath: binary.path)
        do {
            emit(.step(.install, "Installing Bandito on this Mac"))
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

            emit(.step(.service, "Starting the service"))
            let result = try await runner.run(binary.path, ["service", "install", "--json"], stdin: nil)
            let service = try SSHInstaller.serviceOutcome(result)
            try await waitForDaemon(emit: emit)

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
