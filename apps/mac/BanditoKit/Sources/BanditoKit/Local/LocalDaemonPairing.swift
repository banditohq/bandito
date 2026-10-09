import Foundation

/// A paired daemon: the server config with its token, and the id of the device the daemon made for it.
public struct PairedServer: Sendable, Equatable {
    public var config: ServerConfig
    public var deviceID: String

    public init(config: ServerConfig, deviceID: String) {
        self.config = config
        self.deviceID = deviceID
    }
}

/// Gives this Mac's daemon a device token, so the app talks to it like any other WebSocket server.
///
/// `info --json` gives the listen address, `pair --json` a one-time code (the bandito command asks the daemon
/// over its unix socket, so the code is made for this user only), and `pair.redeem` over the WebSocket exchanges
/// the code for the device token. The token then lives in the Keychain, like the tokens of other servers.
public struct LocalDaemonPairing: Sendable {
    /// Exchanges a code for a token at `url`. Default: `Pairing.redeem`.
    public typealias Redeem = @Sendable (_ url: URL, _ code: String, _ deviceName: String) async throws -> PairResult

    private let runner: CommandRunner
    private let binary: URL
    private let home: URL?
    private let redeem: Redeem

    /// - Parameters:
    ///   - runner: runs the bandito binary.
    ///   - binary: the bandito binary that runs this Mac's daemon commands (the installed one).
    ///   - home: passed as `--home` when set. Nil uses the daemon's default home (`$BANDITO_HOME` or `~/.bandito`).
    ///   - redeem: exchanges the code for a token. Default: `Pairing.redeem`.
    public init(runner: CommandRunner, binary: URL, home: URL? = nil, redeem: Redeem? = nil) {
        self.runner = runner
        self.binary = binary
        self.home = home
        self.redeem = redeem ?? { url, code, deviceName in
            try await Pairing.redeem(url: url, code: code, deviceName: deviceName)
        }
    }

    /// This user's installed daemon: `~/.local/bin/bandito`, the default home, and the real redeem.
    public static func installed(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> LocalDaemonPairing {
        LocalDaemonPairing(runner: ProcessCommandRunner(), binary: home.appending(path: ".local/bin/bandito"))
    }

    /// The server config for this Mac's daemon: a WebSocket to its listen port on loopback, with a new device token.
    /// `id` keeps an existing server's identity (its selection and its Keychain item).
    /// Throws `InstallError` when a step fails; nothing is saved here, the caller keeps or drops the result.
    public func serverConfig(name: String, id: UUID = UUID(), deviceName: String) async throws -> ServerConfig {
        try await pair(name: name, id: id, deviceName: deviceName).config
    }

    /// As `serverConfig`, and with the device's id: a caller that cannot keep the token revokes the device with it.
    public func pair(name: String, id: UUID = UUID(), deviceName: String) async throws -> PairedServer {
        let info = try await run(["info", "--json"], step: "Reading the daemon's address")
        guard let port = SSHInstaller.listenPort(in: info.stdout) else {
            throw InstallError.badResponse("info")
        }
        let pair = try await run(["pair", "--json"], step: "Creating a pairing code")
        guard let code = SSHInstaller.pairCode(in: pair.stdout) else {
            throw InstallError.badResponse("pair")
        }
        // Force unwrap: the string is built from a port number and is always a valid URL.
        let url = URL(string: "ws://127.0.0.1:\(port)/v1/rpc")!
        let paired: PairResult
        do {
            paired = try await redeem(url, code, deviceName)
        } catch let error as RPCError {
            throw InstallError.pairingFailed(error.message)
        }
        let config = ServerConfig(id: id, name: name, endpoint: .webSocket(url: url), token: paired.token)
        return PairedServer(config: config, deviceID: paired.device.id)
    }

    /// Runs `bandito [--home <home>] <arguments>`. A non-zero exit throws with the last line of its stderr.
    private func run(_ arguments: [String], step: String) async throws -> CommandResult {
        let leading = home.map { ["--home", $0.path] } ?? []
        let result = try await runner.run(binary.path, leading + arguments, stdin: nil)
        guard result.status == 0 else {
            let last = result.stderr.split(separator: "\n").last.map(String.init) ?? ""
            throw InstallError.step(step, detail: last)
        }
        return result
    }
}
