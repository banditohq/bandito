import Foundation

/// Puts Bandito on this Mac: copies the bandito binary from the app bundle into `~/.local/bin` when it is missing
/// or older, runs `service install --json`, and returns the config that talks to the daemon's unix socket.
/// No token: the socket is trusted for this user (docs/ARCHITECTURE.md#transports).
public struct LocalInstaller: Sendable {
    private let runner: CommandRunner
    private let bundledBinary: URL?
    private let home: URL

    /// - Parameters:
    ///   - runner: runs the installed binary.
    ///   - bundledBinary: the bandito binary inside the app bundle. Default: the auxiliary executable.
    ///   - home: the user's home directory (a test passes a temporary one).
    public init(
        runner: CommandRunner,
        bundledBinary: URL? = Bundle.main.url(forAuxiliaryExecutable: "bandito"),
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
                if try !existed || Self.modified(bundledBinary) > Self.modified(binary) {
                    try Self.copy(bundledBinary, to: binary)
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

    private static func modified(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.modificationDate] as? Date) ?? .distantPast
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }
}
