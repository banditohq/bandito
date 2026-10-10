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
    /// A new stage started: its step (the checklist matches it by this id) and a text for the log.
    case step(InstallStep, String)
    /// A line of output from the install.
    case log(String)
    /// Done: the server is paired and the config can be saved.
    case done(PairInfo)
    /// Stopped. Nothing after this event.
    case failed(InstallError)
}

/// The stages of an install. An install emits one `InstallEvent.step` per stage it enters; the app's checklist groups
/// the stages into its lines by this id, never by the text.
public enum InstallStep: Sendable, Hashable {
    /// Opening the connection to the server (ssh). Not used on this Mac.
    case connect
    /// Reading the server, or this Mac's state, before anything changes.
    case check
    /// Fetching the release (SSH installs only).
    case download
    /// Checking the release's signature and hash (SSH installs only).
    case verify
    /// Putting the binary in place: a copy on this Mac, or the install script on the server.
    case install
    /// Starting the daemon as a user service.
    case service
    /// Creating a pairing code and exchanging it for the app's device token.
    case pair
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
    /// ssh failed with its own message, classified finely enough to act on (host key, key, network).
    case sshFailed(SSHFailure)
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
    /// The release did not pass its check (signature, listing or hash). Nothing was sent to the server.
    case releaseCheckFailed(ReleaseVerifier.Failure)
    /// A release file could not be downloaded. The text says what went wrong.
    case downloadFailed(String)
    /// The release this app needs (`version`, `X.Y.Z`) is not published yet: the newest release is older than the app.
    case releaseStillPublishing(String)
    /// This Mac's daemon did not answer `running: true` in time. The last lines of its log went to the install log.
    case localDaemonNotStarted
    /// The app could not keep the device token in the Keychain, so the server was not added.
    case tokenNotSaved

    public var errorDescription: String? {
        switch self {
        case .ssh(let error):
            return error.errorDescription
        case .sshFailed(let failure):
            return failure.englishDescription
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
        case .releaseCheckFailed:
            return "Release signature check failed — the download may have been tampered with. Nothing was installed."
        case .downloadFailed(let detail):
            return "Downloading Bandito failed: \(detail)"
        case .releaseStillPublishing(let version):
            return "Bandito \(version) for servers is not released yet. Update the app or try again later."
        case .localDaemonNotStarted:
            return "Bandito did not start on this Mac."
        case .tokenNotSaved:
            return "The device token could not be saved in the Keychain. The server was not added."
        }
    }
}

/// Puts Bandito on a server and pairs this app with it (docs/ARCHITECTURE.md#install-and-service,
/// #setup). Each step is one ssh call through `runner`, so tests run it without a network.
///
/// Steps: check the server (`uname`, is `bandito` there), install it if missing (the release from GitHub, checked on
/// this Mac and copied over, or a copied binary), `service install --json`, `info --json` for the listen port,
/// `pair --json` for a code, then `pair.redeem` over an `SSHTunnel` for the token.
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
    #if DEBUG
    private let localBinary: URL?
    private let devArchive: URL?
    #endif
    private let appTag: String?
    private let release: ReleaseSource
    private let releaseKey: ReleaseVerifier.PublicKey
    private let redeem: Redeem

    /// - Parameters:
    ///   - runner: runs ssh and scp.
    ///   - installScript: the install.sh bytes. Default: the copy bundled in the app. The script is never downloaded.
    ///   - appVersion: the app's version. The server gets the release with the same tag; when there is none, the latest
    ///     release is used, with a line in the log. Nil asks for the latest release.
    ///   - release: where the release files come from. Default: GitHub.
    ///   - releaseKey: the key the release must be signed with. Default: the Bandito release key.
    ///   - redeem: exchanges the code for a token. Default: over an `SSHTunnel` to the server.
    #if DEBUG
    /// - Parameters (Debug builds only):
    ///   - localBinary: a bandito build to copy with scp instead of the release (development).
    ///   - devArchive: a local release archive, installed without download and without signature check (development,
    ///     before a release exists).
    public init(
        runner: CommandRunner,
        installScript: @escaping ScriptSource = SSHInstaller.bundledScript,
        localBinary: URL? = nil,
        devArchive: URL? = nil,
        appVersion: String? = nil,
        release: ReleaseSource = GitHubReleaseSource(),
        releaseKey: ReleaseVerifier.PublicKey = ReleaseVerifier.release,
        redeem: Redeem? = nil
    ) {
        self.init(
            runner: runner, installScript: installScript, development: (localBinary, devArchive),
            appVersion: appVersion, release: release, releaseKey: releaseKey, redeem: redeem)
    }
    #else
    public init(
        runner: CommandRunner,
        installScript: @escaping ScriptSource = SSHInstaller.bundledScript,
        appVersion: String? = nil,
        release: ReleaseSource = GitHubReleaseSource(),
        releaseKey: ReleaseVerifier.PublicKey = ReleaseVerifier.release,
        redeem: Redeem? = nil
    ) {
        self.init(
            runner: runner, installScript: installScript, development: (nil, nil),
            appVersion: appVersion, release: release, releaseKey: releaseKey, redeem: redeem)
    }
    #endif

    /// The one place that sets the fields. `development` is the Debug-only pair (nil in Release builds).
    private init(
        runner: CommandRunner,
        installScript: @escaping ScriptSource,
        development: (localBinary: URL?, devArchive: URL?),
        appVersion: String?,
        release: ReleaseSource,
        releaseKey: ReleaseVerifier.PublicKey,
        redeem: Redeem?
    ) {
        self.runner = runner
        self.scriptSource = installScript
        #if DEBUG
        self.localBinary = development.localBinary
        self.devArchive = development.devArchive
        #endif
        self.appTag = appVersion.flatMap(GitHubReleaseSource.tag(forAppVersion:))
        self.release = release
        self.releaseKey = releaseKey
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
            emit(.step(.connect, "Connecting over SSH"))
            emit(.step(.check, "Checking the server"))
            let probeResult = try checked(await remote(target, Self.probeCommand), step: "Checking the server")
            let probe = try RemoteProbe.parse(probeResult.stdout)

            let alreadyInstalled = probe.installedPath != nil
            let binary: String
            if let path = probe.installedPath {
                binary = Self.quoted(path)
            } else {
                binary = Self.remoteBinary
                try await install(on: target, probe: probe, emit: emit)
            }

            emit(.step(.service, "Starting the service"))
            let serviceResult = try await remote(target, "\(binary) service install --json")
            if serviceResult.status == 255 { _ = try checked(serviceResult, step: "Starting the service") }
            let service = try Self.serviceOutcome(serviceResult)

            let infoResult = try checked(await remote(target, "\(binary) info --json"), step: "Reading the daemon")
            guard let listen = Self.listenPort(in: infoResult.stdout) else {
                throw InstallError.badResponse("info")
            }

            emit(.step(.pair, "Creating a pairing code"))
            let pairResult = try checked(await remote(target, "\(binary) pair --json"), step: "Creating a pairing code")
            guard let code = Self.pairCode(in: pairResult.stdout) else {
                throw InstallError.badResponse("pair")
            }

            emit(.step(.pair, "Connecting"))
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

    private func scp(_ local: URL, to target: SSHTarget, remotePath: String = ".local/bin/bandito") async throws -> CommandResult {
        try await runner.run(
            Self.scpExecutable,
            Self.transportOptions + target.scpArguments(local: local.path, remotePath: remotePath),
            stdin: nil)
    }

    /// Puts the binary on the server: the release from GitHub, checked on this Mac first, or (in Debug builds) a copy
    /// of a build or a local archive. Nothing is sent to the server before the check passes.
    private func install(on target: SSHTarget, probe: RemoteProbe, emit: (InstallEvent) -> Void) async throws {
        #if DEBUG
        if let localBinary {
            emit(.step(.install, "Installing Bandito"))
            _ = try checked(await remote(target, "mkdir -p ~/.local/bin"), step: "Installing Bandito")
            _ = try checked(await scp(localBinary, to: target), step: "Copying Bandito")
            _ = try checked(await remote(target, "chmod 755 ~/.local/bin/bandito"), step: "Installing Bandito")
            return
        }
        #endif
        // Read first: a bundle without the script stops here, before anything is downloaded.
        let script = try await scriptSource()
        guard let asset = ReleaseAsset.name(kernel: probe.kernel, machine: probe.arch) else {
            throw InstallError.unsupportedPlatform("\(probe.kernel) \(probe.arch)")
        }
        let work = try Self.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        #if DEBUG
        if let devArchive {
            emit(.step(.install, "Installing Bandito"))
            try await installArchive(devArchive, asset: asset, script: script, signed: nil, on: target, emit: emit)
            return
        }
        #endif

        emit(.step(.download, "Downloading Bandito"))
        let fetched = try await release.fetch(version: appTag, asset: asset, into: work)
        if let tag = fetched.tag {
            emit(.log("Bandito release \(tag)"))
        }
        if fetched.fellBackToLatest, let appTag {
            emit(.log("No Bandito \(appTag) release yet: installing \(fetched.tag ?? "the latest release"), a newer one."))
        }
        emit(.step(.verify, "Verifying the Bandito release"))
        do {
            try ReleaseVerifier.verify(
                sums: fetched.sums, signatureBase64: fetched.signatureBase64,
                archive: try Data(contentsOf: fetched.archive), assetName: asset, key: releaseKey)
        } catch let failure as ReleaseVerifier.Failure {
            throw InstallError.releaseCheckFailed(failure)
        }
        // The server gets the same signed list, and checks the archive it receives against it.
        let sums = work.appending(path: "SHA256SUMS")
        let signature = work.appending(path: "SHA256SUMS.sig")
        try fetched.sums.write(to: sums)
        try Data(fetched.signatureBase64.utf8).write(to: signature)
        emit(.step(.install, "Installing Bandito"))
        try await installArchive(
            fetched.archive, asset: asset, script: script, signed: SignedFiles(sums: sums, signature: signature),
            on: target, emit: emit)
    }

    /// The signed list of a release on this Mac, to send along with the archive.
    struct SignedFiles {
        var sums: URL
        var signature: URL
    }

    /// Copies the files to `~/.cache/bandito-install` on the server and runs install.sh on them. With `signed`, the
    /// script checks the archive against the list and the list's signature (`BANDITO_REQUIRE_SIGNATURE=1`). The
    /// files are removed afterwards, whatever the outcome.
    private func installArchive(
        _ archive: URL, asset: String, script: Data, signed: SignedFiles?, on target: SSHTarget,
        emit: (InstallEvent) -> Void
    ) async throws {
        let remoteDirectory = "~/.cache/bandito-install"
        let remoteArchive = "\(remoteDirectory)/\(asset)"
        let remoteSums = "\(remoteDirectory)/SHA256SUMS"
        let remoteSignature = "\(remoteDirectory)/SHA256SUMS.sig"
        let removal = "rm -f \(remoteArchive) \(remoteSums) \(remoteSignature)"
        _ = try checked(
            await remote(target, "mkdir -p \(remoteDirectory) && chmod 700 \(remoteDirectory)"),
            step: "Installing Bandito")
        let command: String
        var prefix = ""
        var options = "--archive \(remoteArchive)"
        if signed != nil {
            prefix = "env BANDITO_REQUIRE_SIGNATURE=1 "
            options += " --sums \(remoteSums) --sig \(remoteSignature)"
        }
        command = "\(prefix)sh -s -- \(options) --no-service"
        let result: CommandResult
        do {
            _ = try checked(
                await scp(archive, to: target, remotePath: ".cache/bandito-install/\(asset)"),
                step: "Copying Bandito")
            if let signed {
                _ = try checked(
                    await scp(signed.sums, to: target, remotePath: ".cache/bandito-install/SHA256SUMS"),
                    step: "Copying Bandito")
                _ = try checked(
                    await scp(signed.signature, to: target, remotePath: ".cache/bandito-install/SHA256SUMS.sig"),
                    step: "Copying Bandito")
            }
            result = try await remote(target, command, stdin: script)
        } catch {
            _ = try? await remote(target, removal)
            throw error
        }
        _ = try? await remote(target, removal)
        for line in Self.lines(result.stdout + result.stderr) {
            emit(.log(line))
        }
        _ = try checked(result, step: "Installing Bandito")
    }

    /// A new directory that only this user can read, for the files of one install.
    static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "bandito-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Turns a non-zero exit into an error. Status 255 is ssh's own failure and is classified; any other status
    /// is a failed remote step.
    private func checked(_ result: CommandResult, step: String) throws -> CommandResult {
        guard result.status != 0 else { return result }
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        if result.status == 255 {
            throw InstallError.sshFailed(SSHFailure.classify(stderr: text))
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
        let arch = ["arm64": "aarch64", "amd64": "x86_64"][parts[1]] ?? parts[1]
        guard ["Linux", "Darwin"].contains(kernel), ["x86_64", "aarch64"].contains(arch) else {
            throw InstallError.unsupportedPlatform(parts.joined(separator: " "))
        }
        // The second line is the installed binary only when it is an absolute path: without bandito, `command -v`
        // and `ls` print nothing and the os-release lines move up.
        let second = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
        let path = second.hasPrefix("/") ? second : ""
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
        // A cancelled run ends its process: the caller stopped waiting, and nothing else would stop the child.
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
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
                running.attach(process)
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
        } onCancel: {
            running.cancel()
        }
    }
}

/// The child process of one `ProcessCommandRunner.run`, so that a cancelled run can stop it. A cancel that comes
/// before the process starts stops it as soon as it starts.
private final class RunningProcess: @unchecked Sendable {
    // @unchecked: `process` and `cancelled` are guarded by `lock`.
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.withLock {
            self.process = process
            if cancelled, process.isRunning { process.terminate() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
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
