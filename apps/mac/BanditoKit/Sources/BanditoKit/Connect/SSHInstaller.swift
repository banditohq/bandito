import Foundation

/// Runs one external program and reports what it printed. A non-zero exit is a result, not an error.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult
}

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Progress of an install, as the connect screen shows it.
public enum InstallEvent: Sendable, Equatable {
    /// A new stage started. The text is for the user.
    case step(String)
    /// A line of output from the install.
    case log(String)
    /// Done: the server is paired and the config can be saved.
    case done(PairInfo)
    /// Stopped. Nothing after this event.
    case failed(InstallError)
}

/// A server that is installed, running, and paired with this app.
public struct PairInfo: Sendable, Equatable {
    /// The config to save. Its token belongs in the Keychain, not in the synced payload.
    public var server: ServerConfig
    /// True when Bandito was already on the server and this run only paired it.
    public var alreadyInstalled: Bool
    /// What `service install` reported as not quite right (for example, lingering was refused).
    public var warnings: [String]

    public init(server: ServerConfig, alreadyInstalled: Bool, warnings: [String]) {
        self.server = server
        self.alreadyInstalled = alreadyInstalled
        self.warnings = warnings
    }
}

public enum InstallError: Error, Sendable, Equatable, LocalizedError {
    /// ssh itself failed: the classified reason.
    case ssh(SSHTunnelError)
    /// Kernel and architecture the install script does not cover. The text is what `uname` said.
    case unsupportedPlatform(String)
    /// A remote step exited with an error. `detail` is its last line of output.
    case step(String, detail: String)
    /// The daemon printed something that is not the JSON the contract names. The text names the command.
    case badResponse(String)
    /// `service install` reported a failure. The text is its warnings.
    case serviceFailed(String)
    /// The pairing code could not be exchanged for a token.
    case pairingFailed(String)
    /// This build has no bandito binary to install on this Mac.
    case localBinaryMissing
    /// A local file or process failed.
    case io(String)
    /// No install script was passed in, and the app bundle does not contain one.
    case missingInstallScript

    public var errorDescription: String? {
        switch self {
        case .ssh(let error):
            return error.errorDescription
        case .unsupportedPlatform(let uname):
            return "\(uname) is not supported. Bandito runs on Linux and macOS, on x86_64 or arm64."
        case .step(let step, let detail):
            return detail.isEmpty ? "\(step) failed." : "\(step) failed: \(detail)"
        case .badResponse(let command):
            return "The answer to \(command) was not understood."
        case .serviceFailed(let detail):
            return "The Bandito service did not start: \(detail)"
        case .pairingFailed(let detail):
            return "Pairing failed: \(detail)"
        case .localBinaryMissing:
            return "This build does not include the bandito tool."
        case .io(let detail):
            return detail
        case .missingInstallScript:
            return "This build does not include the Bandito install script."
        }
    }
}

/// Puts Bandito on a server and pairs this app with it (docs/ARCHITECTURE.md#install-and-service,
/// #setup). Each step is one ssh call through `runner`, so tests run it without a network.
///
/// Steps: check the server (`uname`, is `bandito` there), install it if missing (install.sh, or a copied
/// binary), `service install --json`, `info --json` for the listen port, `pair --json` for a code, then
/// `pair.redeem` over an `SSHTunnel` for the token.
public struct SSHInstaller: Sendable {
    /// Returns the install script's bytes.
    public typealias ScriptSource = @Sendable () async throws -> Data
    /// Exchanges a pairing code for a device token: `(target, remotePort, code, deviceName)`.
    public typealias Redeem = @Sendable (_ target: String, _ remotePort: Int, _ code: String, _ deviceName: String) async throws -> PairResult

    public static let sshExecutable = "/usr/bin/ssh"
    public static let scpExecutable = "/usr/bin/scp"
    /// Every ssh and scp call: never prompt, and give up on an unreachable host.
    static let transportOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    static let remoteBinary = "~/.local/bin/bandito"
    static let probeCommand =
        "uname -sm; command -v bandito || ls ~/.local/bin/bandito 2>/dev/null; cat /etc/os-release 2>/dev/null | head -3"

    private let runner: CommandRunner
    private let scriptSource: ScriptSource
    private let localBinary: URL?
    private let redeem: Redeem

    /// - Parameters:
    ///   - runner: runs ssh and scp.
    ///   - installScript: the install.sh bytes. Default: the copy bundled in the app. The script is never downloaded.
    ///   - localBinary: a bandito build to copy with scp instead of running install.sh (development).
    ///   - redeem: exchanges the code for a token. Default: over an `SSHTunnel` to the server.
    public init(
        runner: CommandRunner,
        installScript: @escaping ScriptSource = SSHInstaller.bundledScript,
        localBinary: URL? = nil,
        redeem: Redeem? = nil
    ) {
        self.runner = runner
        self.scriptSource = installScript
        self.localBinary = localBinary
        self.redeem = redeem ?? Self.defaultRedeem
    }

    /// Installs and pairs. The stream ends with `.done` or `.failed`.
    /// - Parameters:
    ///   - input: the address as the user typed it (`[user@]host[:port]` or an alias).
    ///   - deviceName: the name this Mac gets on the server.
    public func install(target input: String, deviceName: String) -> AsyncStream<InstallEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: InstallEvent.self)
        let task = Task {
            await run(input: input, deviceName: deviceName) { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(input: String, deviceName: String, emit: (InstallEvent) -> Void) async {
        guard let target = SSHTarget.parse(input) else {
            emit(.failed(.ssh(.invalidTarget)))
            return
        }
        do {
            emit(.step("Checking the server"))
            let probeResult = try checked(await remote(target, Self.probeCommand), step: "Checking the server")
            let probe = try RemoteProbe.parse(probeResult.stdout)

            let alreadyInstalled = probe.installedPath != nil
            let binary: String
            if let path = probe.installedPath {
                binary = Self.quoted(path)
            } else {
                binary = Self.remoteBinary
                emit(.step("Installing Bandito"))
                if let localBinary {
                    _ = try checked(await remote(target, "mkdir -p ~/.local/bin"), step: "Installing Bandito")
                    _ = try checked(await scp(localBinary, to: target), step: "Copying Bandito")
                    _ = try checked(
                        await remote(target, "chmod 755 ~/.local/bin/bandito"), step: "Installing Bandito")
                } else {
                    let script = try await scriptSource()
                    let result = try await remote(target, "sh -s -- --no-service", stdin: script)
                    for line in Self.lines(result.stdout + result.stderr) {
                        emit(.log(line))
                    }
                    _ = try checked(result, step: "Installing Bandito")
                }
            }

            emit(.step("Starting the service"))
            let serviceResult = try await remote(target, "\(binary) service install --json")
            if serviceResult.status == 255 { _ = try checked(serviceResult, step: "Starting the service") }
            let service = try Self.serviceOutcome(serviceResult)

            let infoResult = try checked(await remote(target, "\(binary) info --json"), step: "Reading the daemon")
            guard let listen = Self.listenPort(in: infoResult.stdout) else {
                throw InstallError.badResponse("info")
            }

            emit(.step("Creating a pairing code"))
            let pairResult = try checked(await remote(target, "\(binary) pair --json"), step: "Creating a pairing code")
            guard let code = Self.pairCode(in: pairResult.stdout) else {
                throw InstallError.badResponse("pair")
            }

            emit(.step("Connecting"))
            let paired: PairResult
            do {
                paired = try await redeem(target.description, listen, code, deviceName)
            } catch let error as RPCError {
                throw InstallError.pairingFailed(error.message)
            }
            let server = ServerConfig(
                name: target.description,
                endpoint: .ssh(target: target.description, remotePort: listen),
                token: paired.token)
            emit(.done(PairInfo(server: server, alreadyInstalled: alreadyInstalled, warnings: service.warnings ?? [])))
        } catch let error as InstallError {
            emit(.failed(error))
        } catch let error as SSHTunnelError {
            emit(.failed(.ssh(error)))
        } catch {
            emit(.failed(.io(error.localizedDescription)))
        }
    }

    // MARK: steps

    private func remote(_ target: SSHTarget, _ command: String, stdin: Data? = nil) async throws -> CommandResult {
        try await runner.run(Self.sshExecutable, Self.transportOptions + target.sshArguments + [command], stdin: stdin)
    }

    private func scp(_ local: URL, to target: SSHTarget) async throws -> CommandResult {
        try await runner.run(
            Self.scpExecutable,
            Self.transportOptions + target.scpArguments(local: local.path, remotePath: ".local/bin/bandito"),
            stdin: nil)
    }

    /// Turns a non-zero exit into an error. Status 255 is ssh's own failure and is classified; any other status
    /// is a failed remote step.
    private func checked(_ result: CommandResult, step: String) throws -> CommandResult {
        guard result.status != 0 else { return result }
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        if result.status == 255 {
            throw InstallError.ssh(SSHTunnelError.from(stderr: text))
        }
        throw InstallError.step(step, detail: SSHTunnelError.lastLine(of: text))
    }

    // MARK: answers of the daemon

    /// The fields of `service install --json` that the installer uses.
    struct ServiceReply: Decodable, Equatable {
        var ok: Bool
        var warnings: [String]?
    }

    /// Reads `service install --json`. An `ok: false` answer is a failure carrying its warnings.
    static func serviceOutcome(_ result: CommandResult) throws -> ServiceReply {
        guard let reply = try? JSONDecoder().decode(ServiceReply.self, from: Data(result.stdout.utf8)) else {
            throw InstallError.badResponse("service install")
        }
        guard reply.ok else {
            let detail = (reply.warnings ?? []).joined(separator: "; ")
            throw InstallError.serviceFailed(detail.isEmpty ? "the service did not start" : detail)
        }
        return reply
    }

    /// The port of `info --json`'s `listen` (`127.0.0.1:7878` gives 7878). Nil when there is none.
    static func listenPort(in json: String) -> Int? {
        struct Info: Decodable { var listen: String? }
        guard let info = try? JSONDecoder().decode(Info.self, from: Data(json.utf8)),
            let listen = info.listen,
            let port = listen.split(separator: ":").last.flatMap({ Int($0) }),
            (1...65_535).contains(port)
        else { return nil }
        return port
    }

    /// The code of `pair --json`.
    static func pairCode(in json: String) -> String? {
        struct Pair: Decodable { var code: String }
        guard let pair = try? JSONDecoder().decode(Pair.self, from: Data(json.utf8)), !pair.code.isEmpty else {
            return nil
        }
        return pair.code
    }

    // MARK: defaults

    /// The install script copied into the app bundle. Nothing is downloaded: a bundle without the script
    /// is `InstallError.missingInstallScript`.
    public static let bundledScript: ScriptSource = {
        guard let url = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            throw InstallError.missingInstallScript
        }
        return try Data(contentsOf: url)
    }

    /// Opens an `SSHTunnel` to the daemon's listen port, redeems the code there, and closes the tunnel.
    public static let defaultRedeem: Redeem = { target, remotePort, code, deviceName in
        #if os(macOS)
        let tunnel = try SSHTunnel(target: target, remotePort: remotePort)
        try await tunnel.start()
        do {
            guard let url = await tunnel.localURL else { throw SSHTunnelError.unreachable }
            let result = try await Pairing.redeem(url: url, code: code, deviceName: deviceName)
            await tunnel.stop()
            return result
        } catch {
            await tunnel.stop()
            throw error
        }
        #else
        throw SSHTunnelError.exited(detail: "ssh servers are not available on this platform yet")
        #endif
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// What `uname -sm` and `/etc/os-release` say about a server.
struct RemoteProbe: Equatable {
    var kernel: String
    /// `x86_64` or `aarch64` (`arm64` is reported as `aarch64`).
    var arch: String
    /// Where `bandito` already is, when it is installed.
    var installedPath: String?
    var osName: String?

    static func parse(_ output: String) throws -> RemoteProbe {
        let lines = output.components(separatedBy: "\n")
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        guard parts.count == 2 else { throw InstallError.badResponse("check the server") }
        let kernel = parts[0]
        let arch = parts[1] == "arm64" ? "aarch64" : parts[1]
        guard ["Linux", "Darwin"].contains(kernel), ["x86_64", "aarch64"].contains(arch) else {
            throw InstallError.unsupportedPlatform(parts.joined(separator: " "))
        }
        let path = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
        let prefix = "PRETTY_NAME="
        let osName = lines.first { $0.hasPrefix(prefix) }.map { line -> String in
            var value = String(line.dropFirst(prefix.count))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return RemoteProbe(kernel: kernel, arch: arch, installedPath: path.isEmpty ? nil : path, osName: osName)
    }
}

#if os(macOS)

/// Runs programs with `Process`: stdin from `Data`, stdout and stderr collected in full.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            let input = stdin == nil ? nil : Pipe()
            process.standardOutput = out
            process.standardError = err
            if let input {
                process.standardInput = input
            } else {
                process.standardInput = FileHandle.nullDevice
            }

            let collector = OutputCollector()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global().async {
                collector.readStdout(out.fileHandleForReading)
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global().async {
                collector.readStderr(err.fileHandleForReading)
                readers.leave()
            }
            process.terminationHandler = { finished in
                readers.notify(queue: .global()) {
                    continuation.resume(
                        returning: CommandResult(
                            status: finished.terminationStatus,
                            stdout: collector.stdout,
                            stderr: collector.stderr))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: InstallError.io("could not run \(executable): \(error.localizedDescription)"))
                return
            }
            // Drop this process's copies of the child's pipe ends, or the readers never see end of file.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            if let input, let stdin {
                DispatchQueue.global().async {
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
            }
        }
    }
}

/// Holds what the two readers of a process collected.
// @unchecked: both buffers are guarded by `lock`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func readStdout(_ handle: FileHandle) {
        let data = (try? handle.readToEnd()) ?? Data()
        lock.withLock { out = data }
    }

    func readStderr(_ handle: FileHandle) {
        let data = (try? handle.readToEnd()) ?? Data()
        lock.withLock { err = data }
    }

    var stdout: String {
        lock.withLock { String(decoding: out, as: UTF8.self) }
    }

    var stderr: String {
        lock.withLock { String(decoding: err, as: UTF8.self) }
    }
}

#endif
