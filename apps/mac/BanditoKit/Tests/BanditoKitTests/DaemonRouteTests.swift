import Foundation
import Testing

@testable import BanditoKit

// The daemon's HTTP base and requests for each kind of server (ServerModel+Daemon.swift): a WebSocket server's own
// origin, an ssh server's tunnel port (read again at each request), and this Mac until it is paired.

private func webSocket(_ url: String, token: String? = nil) throws -> ServerConfig {
    ServerConfig(name: "srv", endpoint: .webSocket(url: try #require(URL(string: url))), token: token)
}

private func sshServer(token: String? = "tok") -> ServerConfig {
    ServerConfig(name: "new", endpoint: .ssh(target: "root@new", remotePort: 7878), token: token)
}

// MARK: base

@MainActor
@Test func aWebSocketServersOwnOriginIsItsBase() async throws {
    let (secure, _) = makeModel(config: try webSocket("wss://srv.example.ts.net/v1/rpc"), [])
    #expect(try await secure.daemonHTTPBase() == URL(string: "https://srv.example.ts.net"))
    let (plain, _) = makeModel(config: try webSocket("ws://127.0.0.1:7878/v1/rpc"), [])
    #expect(try await plain.daemonHTTPBase() == URL(string: "http://127.0.0.1:7878"))
}

@MainActor
@Test func anSSHServerUsesTheTunnelsLoopbackPort() async throws {
    let tunnel = FakeTransport(handlers: daemonHandlers(), httpBase: URL(string: "http://127.0.0.1:51000"))
    let (model, _) = makeModel(config: sshServer(), [tunnel])
    await model.connect()
    #expect(try await model.daemonHTTPBase() == URL(string: "http://127.0.0.1:51000"))
}

@MainActor
@Test func aMovedTunnelIsFollowedAtTheNextRequest() async throws {
    let tunnel = FakeTransport(handlers: daemonHandlers(), httpBase: URL(string: "http://127.0.0.1:51000"))
    let (model, _) = makeModel(config: sshServer(), [tunnel])
    await model.connect()
    #expect(try await model.daemonHTTPBase() == URL(string: "http://127.0.0.1:51000"))
    await tunnel.setHTTPBase(URL(string: "http://127.0.0.1:51001"))
    let request = try await model.daemonRequest(path: "/v1/files/raw", query: [(name: "path", value: "/a.txt")])
    #expect(request.url?.absoluteString == "http://127.0.0.1:51001/v1/files/raw?path=/a.txt")
}

@MainActor
@Test func anSSHServerWithoutAConnectedTunnelThrowsDisconnected() async throws {
    let (model, _) = makeModel(config: sshServer(), [])
    do {
        _ = try await model.daemonHTTPBase()
        Issue.record("a base was given without a tunnel")
    } catch let error as RPCError {
        #expect(error.code == RPCError.disconnected)
    }
}

@MainActor
@Test func thisMacHasNoBaseUntilItIsPaired() async throws {
    let (model, _) = makeModel(config: ServerConfig(name: "mac", endpoint: .local(socketPath: "/x/bandito.sock")), [])
    do {
        _ = try await model.daemonHTTPBase()
        Issue.record("a base was given for a server that is not paired")
    } catch let error as RPCError {
        #expect(error.code == RPCError.unsupportedTransport)
    }
}

// MARK: requests

@MainActor
@Test func aSSHFileRequestGoesThroughTheTunnelWithTheToken() async throws {
    let tunnel = FakeTransport(handlers: daemonHandlers(), httpBase: URL(string: "http://127.0.0.1:51000"))
    let (model, _) = makeModel(config: sshServer(token: "tok"), [tunnel])
    await model.connect()
    let request = try await model.rawURLRequest(path: "/w/a b.png")
    #expect(request.url?.absoluteString == "http://127.0.0.1:51000/v1/files/raw?path=/w/a%20b.png")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
}

@MainActor
@Test func theTokenIsAHeaderNeverPartOfTheURL() async throws {
    let (model, _) = makeModel(config: try webSocket("wss://srv.example.ts.net/v1/rpc", token: "bdt_secret"), [])
    let request = try await model.daemonRequest(path: "/v1/browser/cdp", socket: true)
    #expect(request.url?.absoluteString == "wss://srv.example.ts.net/v1/browser/cdp")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bdt_secret")
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
}

@MainActor
@Test func aWebSocketServerWithoutATokenSendsNoAuthorization() async throws {
    let (model, _) = makeModel(config: try webSocket("ws://127.0.0.1:7878/v1/rpc"), [])
    let request = try await model.daemonRequest(path: "/v1/browser/tabs", query: [(name: "workspace", value: "a+b c")])
    #expect(request.url?.absoluteString == "http://127.0.0.1:7878/v1/browser/tabs?workspace=a%2Bb%20c")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@MainActor
@Test func aSocketRequestUsesWsForPlainAndWssForSecureServers() async throws {
    let (plain, _) = makeModel(config: try webSocket("http://127.0.0.1:7878/v1/rpc"), [])
    #expect(try await plain.daemonRequest(path: "/v1/browser/cdp", socket: true).url?.scheme == "ws")
    let (secure, _) = makeModel(config: try webSocket("https://srv.example.ts.net/v1/rpc"), [])
    #expect(try await secure.daemonRequest(path: "/v1/browser/cdp", socket: true).url?.scheme == "wss")
}

@MainActor
@Test func theTokenNeverTravelsOverPlainHTTPToAnotherHost() async throws {
    let (model, _) = makeModel(config: try webSocket("ws://192.168.1.5:7878/v1/rpc", token: "bdt_secret"), [])
    do {
        _ = try await model.daemonRequest(path: "/v1/browser/tabs")
        Issue.record("the token was allowed over plain HTTP")
    } catch let error as RPCError {
        #expect(error.code == RPCError.insecureTransport)
    }
}

// MARK: tunnels (VNC, and the port of a dev server)

@MainActor
@Test func aSSHServersTunnelRequestGoesThroughTheTunnelWithTheToken() async throws {
    let tunnel = FakeTransport(handlers: daemonHandlers(), httpBase: URL(string: "http://127.0.0.1:51000"))
    let (model, _) = makeModel(config: sshServer(token: "tok"), [tunnel])
    await model.connect()
    let request = try await model.forwardRequest(port: 5901)
    #expect(request.url?.absoluteString == "ws://127.0.0.1:51000/v1/tunnel?port=5901")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
}

@MainActor
@Test func aWebSocketServersTunnelIsItsOwnTunnelRoute() async throws {
    let (model, _) = makeModel(config: try webSocket("wss://srv.example.ts.net/v1/rpc", token: "tok"), [])
    let request = try await model.forwardRequest(port: 3000)
    #expect(request.url?.absoluteString == "wss://srv.example.ts.net/v1/tunnel?port=3000")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
}

@MainActor
@Test func anSSHServerForwardsOnALocalPortAndStopsOnDisconnect() async throws {
    let tunnel = FakeTransport(handlers: daemonHandlers(), httpBase: URL(string: "http://127.0.0.1:51000"))
    let (model, _) = makeModel(config: sshServer(token: "tok"), [tunnel])
    await model.connect()
    let local = try await model.forwardOnce(port: 5901)
    #expect(local.host() == "127.0.0.1")
    #expect((local.port ?? 0) > 0)
    #expect(model.forwarders.count == 1)
    await model.disconnect()
    #expect(model.forwarders.isEmpty)
}

@MainActor
@Test func aSSHTunnelForwardWithoutAConnectionThrowsDisconnected() async throws {
    let (model, _) = makeModel(config: sshServer(), [])
    do {
        _ = try await model.forwardOnce(port: 5901)
        Issue.record("a forwarder was started without a tunnel")
    } catch let error as RPCError {
        #expect(error.code == RPCError.disconnected)
    }
    #expect(model.forwarders.isEmpty)
}
