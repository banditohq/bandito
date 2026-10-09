import Foundation
import Testing

@testable import BanditoKit

// Manual integration check on this Mac, through the path the app uses for it: `info --json`, `pair --json`,
// `pair.redeem` over the WebSocket, then the browser routes. Start a daemon on a temporary home first:
//   bandito --home <home> daemon --listen 127.0.0.1:17779
// then run with BANDITO_BROWSER_APP_IT=1, BANDITO_LOCAL_DAEMON_BINARY=<bandito binary> and
// BANDITO_LOCAL_DAEMON_HOME=<home>. Skipped in normal runs. It never touches the default home.

private let appIT = ProcessInfo.processInfo.environment["BANDITO_BROWSER_APP_IT"] == "1"

@MainActor
@Test(.enabled(if: appIT))
func thisMacPairsAndReachesAPageThroughTheDaemonRoutes() async throws {
    let env = ProcessInfo.processInfo.environment
    let binary = try #require(env["BANDITO_LOCAL_DAEMON_BINARY"].map { URL(fileURLWithPath: $0) })
    let home = try #require(env["BANDITO_LOCAL_DAEMON_HOME"].map { URL(fileURLWithPath: $0) })
    let pairing = LocalDaemonPairing(runner: ProcessCommandRunner(), binary: binary, home: home)
    let config = try await pairing.serverConfig(name: "it", deviceName: "app-it")
    let server = ServerModel(config: config)
    await server.connect()

    let status = try await server.browserStart()
    #expect(status.isRelay)

    let (client, tab) = try await server.browserPageClient()
    #expect(tab.isPage)
    _ = try await client.send(.navigate(url: "data:text/html,<title>app-it</title><p>ok</p>"))
    let evaluated = try await client.send(.evaluate(expression: "1 + 1"))
    // Runtime.evaluate answers {"result": {"type", "value", …}}: the value is one level down.
    #expect(evaluated["result"]?["value"] == .number(2))
    await client.close()

    // A tab that does not exist: the route answers 404, which the app reports as no such tab.
    let request = try await server.daemonRequest(path: "/v1/browser/cdp/page/NOSUCHTAB", socket: true)
    await #expect(throws: CDPError.noSuchTab) {
        _ = try await URLSessionCDPSocket.open(request: request)
    }

    // The browser-level socket opens and answers.
    let browser = try await server.browserTargetsClient()
    let targets = try await browser.send(.getTargets)
    #expect(targets["targetInfos"] != nil)
    await browser.close()

    // Sixteen browser-level sockets per device; the seventeenth is refused with 429.
    var held: [CDPClient] = []
    for _ in 0..<16 {
        held.append(try await server.browserTargetsClient())
    }
    await #expect(throws: CDPError.tooManySockets) {
        _ = try await server.browserTargetsClient()
    }
    for client in held {
        await client.close()
    }

    try await server.browserStop()
    await #expect(throws: CDPError.browserNotRunning) {
        _ = try await server.browserTabs()
    }
    await server.disconnect()
}
