import Foundation
import Testing

@testable import BanditoKit

@Suite struct ServerAddressTests {
    @Test func localDaemonIsThisMac() {
        let endpoint = ServerEndpoint.local(socketPath: "/Users/u/.bandito/bandito.sock")
        #expect(ServerAddress(endpoint: endpoint) == .thisMac)
    }

    @Test func sshShowsUserAndHostWithoutPort() {
        #expect(ServerAddress(endpoint: .ssh(target: "deploy@example.com:2222", remotePort: 7878)) == .remote("deploy@example.com"))
        #expect(ServerAddress(endpoint: .ssh(target: "example.com", remotePort: 7878)) == .remote("example.com"))
    }

    @Test func webSocketShowsHostAndPortWithoutSchemeOrPath() {
        let loopback = ServerEndpoint.webSocket(url: URL(string: "ws://127.0.0.1:17881/v1/rpc")!)
        #expect(ServerAddress(endpoint: loopback) == .remote("127.0.0.1:17881"))

        let tailnet = ServerEndpoint.webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!)
        #expect(ServerAddress(endpoint: tailnet) == .remote("srv.example.ts.net"))
    }

    @Test func missingHostShowsADashNotTheURL() {
        let endpoint = ServerEndpoint.webSocket(url: URL(string: "ws:/v1/rpc?token=secret")!)
        #expect(ServerAddress(endpoint: endpoint) == .remote("—"))
    }

    @Test func ipv6HostKeepsBrackets() {
        let endpoint = ServerEndpoint.webSocket(url: URL(string: "ws://[::1]:7878/v1/rpc")!)
        #expect(ServerAddress(endpoint: endpoint) == .remote("[::1]:7878"))
    }

    @Test func displayedAddressNeverContainsTokenOrId() {
        let config = ServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            name: "vps",
            endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:17881/v1/rpc")!),
            token: "secret-token-value")
        guard case .remote(let text) = ServerAddress(endpoint: config.endpoint) else {
            Issue.record("expected a remote address")
            return
        }
        #expect(!text.contains("secret-token-value"))
        #expect(!text.contains("00000000-0000-0000-0000-00000000000A"))
        #expect(!text.contains("ServerConfig"))
    }

    @Test func descriptionShowsNameAndKindOnly() {
        let config = ServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!,
            name: "vps",
            endpoint: .webSocket(url: URL(string: "wss://secret-host.example.ts.net:7878/v1/rpc")!),
            token: "secret-token-value")
        #expect(config.description == "ServerConfig(name: vps, connection: WebSocket)")
        #expect(!config.description.contains("secret"))
        #expect(!config.description.contains("ABCD"))
    }

    @Test func descriptionForSSHAndLocalShowsKindOnly() {
        let ssh = ServerConfig(name: "prod", endpoint: .ssh(target: "deploy@10.0.0.5", remotePort: 7878))
        #expect(ssh.description == "ServerConfig(name: prod, connection: ssh)")
        let local = ServerConfig(name: "This Mac", endpoint: .local(socketPath: "/Users/u/.bandito/bandito.sock"))
        #expect(local.description == "ServerConfig(name: This Mac, connection: local)")
    }
}
