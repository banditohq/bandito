@testable import BanditoKit
import Foundation
import Testing

/// A server's address and how it is reached: the ssh fields and the arguments ssh gets, a record saved with the old
/// one-text address, the checks of the form, a server that is switched off, and the connection check.
@MainActor
@Suite struct SSHConnectionTests {
    /// Counts how many transports a model made. Only the test reads it, after the calls are done.
    final class Counter: @unchecked Sendable {
        var made = 0
    }

    // MARK: Fields and the old text

    @Test func aTargetTextBecomesFields() {
        #expect(SSHServerAddress(parsing: "deploy@example.com:2222") == SSHServerAddress(host: "example.com", user: "deploy", port: 2222))
        #expect(SSHServerAddress(parsing: "box")?.host == "box")
        #expect(SSHServerAddress(parsing: "-oProxyCommand=x") == nil)
        #expect(SSHServerAddress(parsing: "two words") == nil)
    }

    @Test func aRecordWithTheOldTextReadsAsFields() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Old","endpoint":{"ssh":{"target":"deploy@example.com:2222","remotePort":7878}}}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(raw.utf8))
        #expect(
            config.endpoint
                == .ssh(server: SSHServerAddress(host: "example.com", user: "deploy", port: 2222), remotePort: 7878))
    }

    @Test func anUnreadableOldTextKeepsTheHostSoTheFailureSaysWhy() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Odd","endpoint":{"ssh":{"target":"-oProxy","remotePort":7878}}}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(raw.utf8))
        guard case .ssh(let server, _) = config.endpoint else {
            Issue.record("wrong endpoint \(config.endpoint)")
            return
        }
        #expect(server.host == "-oProxy")
    }

    @Test func theFieldsRoundTrip() throws {
        let endpoint = ServerEndpoint.ssh(
            server: SSHServerAddress(host: "box.local", user: "ana", port: 2200, identityFile: "/Users/ana/.ssh/id_ed25519"),
            remotePort: 7878)
        let data = try JSONEncoder().encode(endpoint)
        #expect(try JSONDecoder().decode(ServerEndpoint.self, from: data) == endpoint)
    }

    @Test func aWebSocketAndALocalEndpointStillRoundTrip() throws {
        let websocket = ServerEndpoint.webSocket(url: URL(string: "wss://mac.example.ts.net:7878/v1/rpc")!)
        let local = ServerEndpoint.local(socketPath: "/tmp/bandito-test.sock")
        for endpoint in [websocket, local] {
            let data = try JSONEncoder().encode(endpoint)
            #expect(try JSONDecoder().decode(ServerEndpoint.self, from: data) == endpoint)
        }
    }

    @Test func aDisabledFlagMissingFromAnOldRecordReadsAsOff() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Old","endpoint":{"local":{"socketPath":"/tmp/x.sock"}}}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(raw.utf8))
        #expect(!config.disabled)
    }

    @Test func theTextFactoryKeepsTheRemotePort() {
        #expect(
            ServerEndpoint.ssh(target: "root@new", remotePort: 7878)
                == .ssh(server: SSHServerAddress(host: "new", user: "root"), remotePort: 7878))
    }

    // MARK: The form

    @Test func theFormAcceptsAHostAndTheOptionalFieldsEmpty() {
        #expect(
            SSHServerAddress.validated(host: " box.example ", user: "", port: "", identityFile: "")
                == .success(SSHServerAddress(host: "box.example")))
    }

    @Test func theFormKeepsEveryFieldItGets() {
        #expect(
            SSHServerAddress.validated(
                host: "box", user: "ana", port: "2222", identityFile: "~/.ssh/id_ed25519", isRegularFile: { _ in true })
                == .success(SSHServerAddress(host: "box", user: "ana", port: 2222, identityFile: "~/.ssh/id_ed25519")))
    }

    @Test func aKeyFileMustExistAndBeARegularFile() {
        let missing = SSHServerAddress.validated(
            host: "box", user: "", port: "", identityFile: "/nope/id", isRegularFile: { _ in false })
        #expect(missing == .failure(.identityFile))
        // The real check: a folder is not a key file, and a missing path is not either.
        #expect(!SSHServerAddress.isRegularFile("/nonexistent-\(UUID().uuidString)"))
        #expect(!SSHServerAddress.isRegularFile(NSTemporaryDirectory()))
        let file = FileManager.default.temporaryDirectory.appending(path: "bandito-key-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("key".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SSHServerAddress.isRegularFile(file.path))
    }

    /// The host and the user never reach ssh as an option: a name with a dash first, or with a character outside the
    /// name set, is refused before anything runs.
    @Test func anOptionInTheHostOrTheUserIsRefused() {
        let injected = ["-oProxyCommand=touch /tmp/pwned", "-oLocalCommand=id", "box;id", "$(id)", "box`id`", "--help"]
        for text in injected {
            #expect(SSHServerAddress.validated(host: text, user: "", port: "", identityFile: nil) == .failure(.host))
            #expect(SSHServerAddress.validated(host: "box", user: text, port: "", identityFile: nil) == .failure(.user))
            #expect(SSHServerAddress(parsing: text) == nil)
        }
        #expect(
            SSHServerAddress.validated(
                host: "box", user: "", port: "", identityFile: "-oProxyCommand=touch /tmp/pwned", isRegularFile: { _ in true })
                == .failure(.identityFile))
    }

    /// A record that already holds such a host (edited by hand, or written by something else) still cannot become an
    /// option: the `--` before the destination ends the options.
    @Test func theDestinationComesAfterTheDoubleDashSoItIsNeverAnOption() {
        let target = SSHTarget(user: nil, host: "-oProxyCommand=touch /tmp/pwned", port: nil)
        #expect(target.sshArguments == ["--", "-oProxyCommand=touch /tmp/pwned"])
        #expect(target.scpArguments(local: "a.pkg", remotePath: "/tmp/a.pkg").prefix(1) == ["--"])
        let args = SSHTunnel.arguments(target: target, localPort: 5000, remotePort: 7878)
        #expect(args.suffix(2) == ["--", "-oProxyCommand=touch /tmp/pwned"])
    }

    /// The app of 0.1.10 read `ssh` as the one text `target` and `remotePort`. This is that reader: a record written by
    /// this build must still give it the server.
    private struct Legacy0110Endpoint: Decodable {
        struct SSH: Decodable {
            let target: String
            let remotePort: Int
        }
        let ssh: SSH
    }

    @Test func aRecordWrittenNowReadsWithTheOldDecoder() throws {
        let endpoint = ServerEndpoint.ssh(
            server: SSHServerAddress(host: "box", user: "ana", port: 2222, identityFile: "/k/id"), remotePort: 7878)
        let data = try JSONEncoder().encode(endpoint)
        let old = try JSONDecoder().decode(Legacy0110Endpoint.self, from: data)
        #expect(old.ssh.target == "ana@box:2222")
        #expect(old.ssh.remotePort == 7878)
    }

    @Test func theFormNamesTheFieldThatIsWrong() {
        #expect(SSHServerAddress.validated(host: "", user: "", port: "", identityFile: nil) == .failure(.host))
        #expect(SSHServerAddress.validated(host: "-oProxy", user: "", port: "", identityFile: nil) == .failure(.host))
        #expect(SSHServerAddress.validated(host: "a b", user: "", port: "", identityFile: nil) == .failure(.host))
        #expect(SSHServerAddress.validated(host: "box", user: "bad user", port: "", identityFile: nil) == .failure(.user))
        for port in ["0", "65536", "22a", "-1", "+22"] {
            #expect(SSHServerAddress.validated(host: "box", user: "", port: port, identityFile: nil) == .failure(.port))
        }
        #expect(SSHServerAddress.validated(host: "box", user: "", port: "", identityFile: "-oProxy") == .failure(.identityFile))
        #expect(SSHServerAddress.validated(host: "box", user: "", port: "", identityFile: "a\nb") == .failure(.identityFile))
    }

    // MARK: Arguments

    @Test func sshGetsTheKeyBeforeThePortAndTheDestination() {
        let keyed = SSHTarget(user: "ana", host: "box", port: 2222, identityFile: "/k/id")
        #expect(keyed.sshArguments == ["-i", "/k/id", "-p", "2222", "--", "ana@box"])
        #expect(SSHTarget(user: nil, host: "box", port: nil).sshArguments == ["--", "box"])
    }

    @Test func theTunnelForwardsWithTheKeyToo() {
        let args = SSHTunnel.arguments(
            target: SSHTarget(user: nil, host: "box", port: 22, identityFile: "/k/id"), localPort: 5000, remotePort: 7878)
        #expect(args.suffix(6) == ["-i", "/k/id", "-p", "22", "--", "box"])
        #expect(args.contains("127.0.0.1:5000:127.0.0.1:7878"))
    }

    @Test func scpGetsTheKeyAndItsOwnPortFlag() {
        let target = SSHTarget(user: "ana", host: "box", port: 2222, identityFile: "/k/id")
        #expect(target.scpArguments(local: "a.pkg", remotePath: "/tmp/a.pkg") == ["-i", "/k/id", "-P", "2222", "--", "a.pkg", "ana@box:/tmp/a.pkg"])
    }

    @Test func theTargetTextLeavesTheKeyOut() {
        let address = SSHServerAddress(host: "box", user: "ana", port: 2222, identityFile: "/k/id")
        #expect(address.targetText == "ana@box:2222")
        #expect(address.target.identityFile == "/k/id")
    }

    // MARK: Endpoint rules

    @Test func replacingTheAddressKeepsTheDaemonPort() {
        let endpoint = ServerEndpoint.ssh(server: SSHServerAddress(host: "old"), remotePort: 7900)
        let replaced = ServerEndpointRules.replacingSSH(endpoint, with: SSHServerAddress(host: "new", user: "ana"))
        #expect(replaced == .ssh(server: SSHServerAddress(host: "new", user: "ana"), remotePort: 7900))
        #expect(ServerEndpointRules.replacingSSH(.local(socketPath: "/tmp/x.sock"), with: SSHServerAddress(host: "x")) == nil)
    }

    @Test func aWebSocketAddressNeedsItsSchemeAndAHost() {
        #expect(ServerEndpointRules.webSocketURL("ws://10.0.0.5:7878/v1/rpc") != nil)
        #expect(ServerEndpointRules.webSocketURL("wss://mac.example.ts.net:7878/v1/rpc") != nil)
        #expect(ServerEndpointRules.webSocketURL("https://example.com") == nil)
        #expect(ServerEndpointRules.webSocketURL("ws://") == nil)
        #expect(ServerEndpointRules.webSocketURL("not a url") == nil)
    }

    @Test func aLocalDaemonIsNotEditableAndTheOthersAre() {
        #expect(!ServerEndpointRules.isEditable(.local(socketPath: "/tmp/x.sock")))
        #expect(ServerEndpointRules.isEditable(.ssh(server: SSHServerAddress(host: "box"), remotePort: 7878)))
        #expect(ServerEndpointRules.isEditable(.webSocket(url: URL(string: "ws://10.0.0.5:7878/v1/rpc")!)))
    }

    // MARK: Switched off, and the check

    @Test func aServerSwitchedOffDoesNotConnect() async {
        let counter = Counter()
        let model = ServerModel(
            config: ServerConfig(
                name: "off", endpoint: .ssh(server: SSHServerAddress(host: "box"), remotePort: 7878), disabled: true),
            makeTransport: { _ in
                counter.made += 1
                return UnavailableTransport(reason: "should not be asked")
            })
        await model.connect()
        #expect(model.state == .disconnected)
        #expect(counter.made == 0)
    }

    @Test func aCheckThatCannotReachTheServerSaysNoAnswer() async {
        let model = ServerModel(
            config: ServerConfig(name: "box", endpoint: .ssh(server: SSHServerAddress(host: "box"), remotePort: 7878)),
            makeTransport: { _ in UnavailableTransport(reason: "no route") })
        #expect(await model.checkConnection() == .failed(.noAnswer))
        #expect(model.state == .disconnected)
    }
}
