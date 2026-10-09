import Foundation
import Testing

@testable import BanditoKit

// The address and headers of the browser routes, the errors their HTTP answers map to, and the reconnect
// policy (docs/ARCHITECTURE.md#browser). Nothing here opens a connection.

@Test func tabsRouteUsesTheServersOriginOverPlainHTTP() throws {
    let server = try #require(URL(string: "ws://127.0.0.1:7878/v1/rpc"))
    let url = BrowserRoute.url(server: server, path: "/v1/browser/tabs", workspace: nil, socket: false)
    #expect(url?.absoluteString == "http://127.0.0.1:7878/v1/browser/tabs")
}

@Test func socketsUseWsOrWssAndSecureServersAreHTTPSOrWss() throws {
    let plain = try #require(URL(string: "ws://127.0.0.1:7878/v1/rpc"))
    let secure = try #require(URL(string: "wss://mac.example.ts.net/v1/rpc"))
    #expect(
        BrowserRoute.url(server: plain, path: "/v1/browser/cdp", workspace: nil, socket: true)?.absoluteString
            == "ws://127.0.0.1:7878/v1/browser/cdp")
    #expect(
        BrowserRoute.url(server: secure, path: "/v1/browser/cdp", workspace: nil, socket: true)?.absoluteString
            == "wss://mac.example.ts.net/v1/browser/cdp")
    #expect(
        BrowserRoute.url(server: secure, path: "/v1/browser/tabs", workspace: nil, socket: false)?.absoluteString
            == "https://mac.example.ts.net/v1/browser/tabs")
}

@Test func sshTunnelAddressBuildsThePageSocket() throws {
    // What `SSHTunnel.localURL` gives: the tunnel's loopback port, in front of the daemon.
    let tunnel = try #require(URL(string: "ws://127.0.0.1:51000/v1/rpc"))
    let url = BrowserRoute.url(
        server: tunnel, path: "/v1/browser/cdp/page/ABC", workspace: nil, socket: true)
    #expect(url?.absoluteString == "ws://127.0.0.1:51000/v1/browser/cdp/page/ABC")
}

@Test func workspaceIsOneEncodedQueryValueAndTheFragmentIsDropped() throws {
    let server = try #require(URL(string: "http://127.0.0.1:7878/v1/rpc#part"))
    let url = BrowserRoute.url(server: server, path: "/v1/browser/tabs", workspace: "a+b c", socket: false)
    #expect(url?.absoluteString == "http://127.0.0.1:7878/v1/browser/tabs?workspace=a%2Bb%20c")
}

@Test func targetIDsAreOneToSixtyFourLettersOrDigits() {
    #expect(BrowserRoute.isValidTargetID("ABC123"))
    #expect(BrowserRoute.isValidTargetID(String(repeating: "A", count: 64)))
    for bad in ["", "a/b", "a-b", "a b", String(repeating: "A", count: 65), "é1", "A?x"] {
        #expect(!BrowserRoute.isValidTargetID(bad), "\(bad)")
    }
}

@MainActor
@Test func theDeviceTokenTravelsInTheHeaderNotTheURL() throws {
    let server = ServerModel(
        config: ServerConfig(
            name: "mac", endpoint: .webSocket(url: try #require(URL(string: "ws://127.0.0.1:7878/v1/rpc"))),
            token: "bdt_secret"))
    let request = try server.browserRequest(path: "/v1/browser/cdp", workspace: nil, socket: true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bdt_secret")
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(request.url?.absoluteString == "ws://127.0.0.1:7878/v1/browser/cdp")
}

@MainActor
@Test func aServerWithoutATokenSendsNoAuthorization() throws {
    let server = ServerModel(
        config: ServerConfig(
            name: "mac", endpoint: .webSocket(url: try #require(URL(string: "ws://127.0.0.1:7878/v1/rpc")))))
    let request = try server.browserRequest(path: "/v1/browser/tabs", workspace: "work", socket: false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.url?.absoluteString == "http://127.0.0.1:7878/v1/browser/tabs?workspace=work")
}

@MainActor
@Test func aTokenOverPlainHTTPToAnotherHostIsRefused() throws {
    let server = ServerModel(
        config: ServerConfig(
            name: "office", endpoint: .webSocket(url: try #require(URL(string: "ws://192.168.1.5:7878/v1/rpc"))),
            token: "bdt_secret"))
    do {
        _ = try server.browserRequest(path: "/v1/browser/tabs", workspace: nil, socket: false)
        Issue.record("the token was allowed over plain HTTP")
    } catch let error as RPCError {
        #expect(error.code == RPCError.insecureTransport)
    }
}

@MainActor
@Test func sshAndThisMacHaveNoBrowserRouteYet() throws {
    let ssh = ServerModel(config: ServerConfig(name: "new", endpoint: .ssh(target: "root@new", remotePort: 7878), token: "t"))
    let local = ServerModel(config: ServerConfig(name: "mac", endpoint: .local(socketPath: "/tmp/x.sock")))
    for server in [ssh, local] {
        do {
            _ = try server.browserRequest(path: "/v1/browser/tabs", workspace: nil, socket: false)
            Issue.record("a route was built for \(server.config.name)")
        } catch let error as RPCError {
            #expect(error.code == RPCError.unsupportedTransport)
        }
    }
}

@Test func routeAnswersMapToTheirErrors() {
    #expect(CDPError.routeError(status: 409) == .browserNotRunning)
    #expect(CDPError.routeError(status: 404) == .noSuchTab)
    #expect(CDPError.routeError(status: 429) == .tooManySockets)
    #expect(CDPError.routeError(status: 401) == .unauthorized)
    #expect(CDPError.routeError(status: 403) == .unauthorized)
    #expect(CDPError.routeError(status: 500) == .httpStatus(500))
}

@Test func reconnectWaitsTwoSecondsBetweenAttempts() {
    var policy = BrowserReconnectPolicy()
    #expect(policy.next(at: 0) == .attempt(1))
    #expect(policy.next(at: 1) == .wait(until: 2))
    #expect(policy.next(at: 2) == .attempt(2))
    #expect(policy.next(at: 2.5) == .wait(until: 4))
}

@Test func fiveFailuresInARowGiveUpUntilAConnectionWorks() {
    var policy = BrowserReconnectPolicy()
    var now: TimeInterval = 0
    for attempt in 1...BrowserReconnectPolicy.maxAttempts {
        #expect(policy.next(at: now) == .attempt(attempt))
        now += 2
    }
    #expect(policy.next(at: now) == .giveUp)
    #expect(policy.next(at: now + 3600) == .giveUp)
    policy.succeeded()
    #expect(policy.next(at: now) == .attempt(1))
}

@Test func aConnectionThatShowsSomethingRestartsTheCount() {
    var policy = BrowserReconnectPolicy()
    #expect(policy.next(at: 0) == .attempt(1))
    #expect(policy.next(at: 1) == .wait(until: 2))
    policy.succeeded()
    #expect(policy.attempts == 0)
    // After a success the next drop is retried at once, not after the old wait.
    #expect(policy.next(at: 1) == .attempt(1))
}
