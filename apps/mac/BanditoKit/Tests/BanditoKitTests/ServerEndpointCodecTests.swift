import Foundation
import Testing

@testable import BanditoKit

@Suite struct ServerEndpointCodecTests {
    @Test func configsSavedBeforeSSHExistedStillDecode() throws {
        let local = #"{"id":"00000000-0000-0000-0000-000000000001","name":"This Mac","endpoint":{"local":{"socketPath":"/Users/u/.bandito/bandito.sock"}}}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(local.utf8))
        #expect(config.name == "This Mac")
        #expect(config.endpoint == .local(socketPath: "/Users/u/.bandito/bandito.sock"))
        #expect(config.token == nil)

        let remote = #"{"id":"00000000-0000-0000-0000-000000000002","name":"vps","endpoint":{"webSocket":{"url":"wss://srv.example.ts.net/v1/rpc"}}}"#
        let webSocket = try JSONDecoder().decode(ServerConfig.self, from: Data(remote.utf8))
        #expect(webSocket.endpoint == .webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!))
    }

    @Test func sshEndpointRoundTrips() throws {
        let config = ServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "prod-1",
            endpoint: .ssh(target: "deploy@example.com:2222", remotePort: 7878))

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)

        #expect(decoded == config)
        #expect(String(decoding: data, as: UTF8.self).contains("\"ssh\""))
    }

    @Test func tokenIsNeverWrittenToDisk() throws {
        let config = ServerConfig(
            name: "prod-1", endpoint: .ssh(target: "prod-1", remotePort: 7878), token: "very-secret-token")

        let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)

        #expect(!text.contains("very-secret-token"))
    }
}
