import CryptoKit
import Foundation

/// Puts Bandito on this Mac: copies the bandito binary from the app bundle into `~/.local/bin` when it is missing
/// or different (SHA-256), runs `service install --json`, and returns the config that talks to the daemon's unix socket.
/// No token: the socket is trusted for this user (docs/ARCHITECTURE.md#transports).
public struct LocalInstaller: Sendable {
    private let runner: CommandRunner
    private let bundledBinary: URL?
    private let home: URL

    /// Where the app bundle keeps the daemon: `Contents/Helpers/bandito`. Helpers, not MacOS: on a
    /// case-insensitive volume `MacOS/bandito` would be the app's own `Bandito` executable.
    public static func bundledDaemonURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appending(path: "Contents/Helpers/bandito")
    }

    /// - Parameters:
    ///   - runner: runs the installed binary.
    ///   - bundledBinary: the bandito binary inside the app bundle. Default: `Contents/Helpers/bandito`.
    ///   - home: the user's home directory (a test passes a temporary one).
    public init(
        runner: CommandRunner,
        bundledBinary: URL? = LocalInstaller.bundledDaemonURL(),
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.runner = runner
        self.bundledBinary = bundledBinary
        self.home = home
    }

    /// Installs and starts the service. The stream ends with `.done` or `.failed`.
    public func install() -> AsyncStream<InstallEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: InstallEvent.self)
        let task = Task {
            await run { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(emit: (InstallEvent) -> Void) async {
        let binary = home.appending(path: ".local/bin/bandito")
        let existed = FileManager.default.fileExists(atPath: binary.path)
        do {
            emit(.step("Installing Bandito on this Mac"))
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

            emit(.step("Starting the service"))
            let result = try await runner.run(binary.path, ["service", "install", "--json"], stdin: nil)
            let service = try SSHInstaller.serviceOutcome(result)

            let server = ServerConfig(
                name: "This Mac",
                endpoint: .local(socketPath: home.appending(path: ".bandito/bandito.sock").path))
            emit(
                .done(
                    PairInfo(server: server, alreadyInstalled: existed, warnings: service.warnings ?? [])))
        } catch let error as InstallError {
            emit(.failed(error))
        } catch {
            emit(.failed(.io(error.localizedDescription)))
        }
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
