import Foundation
import Testing

@testable import BanditoKit

// Manual integration check on this Mac: a service on the daemon's host (a local HTTP server started by hand) is
// reached through `forwardOnce` (the VNC and dev-server path) and through the preview proxy `/v1/proxy/<port>`.
// Start the service and a temporary daemon first:
//   python3 -m http.server <service port> --bind 127.0.0.1 --directory <dir with marker.txt>
//   bandito --home <home> daemon --listen 127.0.0.1:<daemon port>
// then run with BANDITO_TUNNEL_IT=1, BANDITO_LOCAL_DAEMON_BINARY, BANDITO_LOCAL_DAEMON_HOME and
// BANDITO_TUNNEL_SERVICE_PORT=<service port>. Skipped in normal runs. It never touches the default home.

private let tunnelIT = ProcessInfo.processInfo.environment["BANDITO_TUNNEL_IT"] == "1"

/// `marker.txt` in the service's directory, fetched through `url`. Returns the body text.
private func fetchMarker(_ request: URLRequest) async throws -> (status: Int, body: String) {
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, String(decoding: data, as: UTF8.self))
}

@MainActor
@Test(.enabled(if: tunnelIT))
func aServiceOnTheDaemonsHostIsReachedThroughTheTunnelAndThePreviewProxy() async throws {
    let env = ProcessInfo.processInfo.environment
    let binary = try #require(env["BANDITO_LOCAL_DAEMON_BINARY"].map { URL(fileURLWithPath: $0) })
    let home = try #require(env["BANDITO_LOCAL_DAEMON_HOME"].map { URL(fileURLWithPath: $0) })
    let servicePort = try #require(env["BANDITO_TUNNEL_SERVICE_PORT"].flatMap(Int.init))
    let pairing = LocalDaemonPairing(runner: ProcessCommandRunner(), binary: binary, home: home)
    let paired = try await pairing.serverConfig(name: "it", deviceName: "tunnel-it")
    let token = try #require(paired.token)

    // 1. A WebSocket server: the tunnel through `forwardOnce`, then the marker through the local port.
    let web = ServerModel(config: paired)
    await web.connect()
    let local = try await web.forwardOnce(port: servicePort)
    let viaTunnel = try await fetchMarker(URLRequest(url: local.appending(path: "marker.txt")))
    #expect(viaTunnel.status == 200)
    #expect(viaTunnel.body.contains("marker-7f3a"))
    await web.disconnect()

    // 2. The preview proxy: the same service through the daemon's `/v1/proxy/<port>/…` route.
    let proxied = try await web.daemonRequest(encodedPath: "/v1/proxy/\(servicePort)/marker.txt", encodedQuery: nil)
    let viaProxy = try await fetchMarker(proxied)
    #expect(viaProxy.status == 200)
    #expect(viaProxy.body.contains("marker-7f3a"))

    // 3. The ssh path, with a stand-in tunnel: the daemon's own loopback port, as `ssh -L` would give it. The ssh
    //    server carries the same token, and the base comes from its transport.
    let daemonPort = try #require(paired.endpoint.webSocketPort)
    let stand = FakeTransport(handlers: daemonHandlers(), httpBase: URL(string: "http://127.0.0.1:\(daemonPort)"))
    let ssh = ServerModel(
        config: ServerConfig(name: "ssh-it", endpoint: .ssh(target: "root@localhost", remotePort: daemonPort), token: token),
        makeTransport: { _ in stand },
        reconnectDelay: { _ in .milliseconds(10) })
    await ssh.connect()
    let sshLocal = try await ssh.forwardOnce(port: servicePort)
    let viaSSH = try await fetchMarker(URLRequest(url: sshLocal.appending(path: "marker.txt")))
    #expect(viaSSH.body.contains("marker-7f3a"))
    let sshProxied = try await ssh.daemonRequest(encodedPath: "/v1/proxy/\(servicePort)/marker.txt", encodedQuery: nil)
    #expect(try await fetchMarker(sshProxied).body.contains("marker-7f3a"))
    await ssh.disconnect()
}

private extension ServerEndpoint {
    /// The port of a WebSocket endpoint, for the stand-in tunnel.
    var webSocketPort: Int? {
        if case .webSocket(let url) = self { return url.port }
        return nil
    }
}
