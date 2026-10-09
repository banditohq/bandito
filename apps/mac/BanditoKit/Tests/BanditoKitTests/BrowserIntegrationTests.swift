import Foundation
import Testing

@testable import BanditoKit

// Manual integration check against a running daemon: the app's own routes, the tabs, and one page evaluated over
// `WS /v1/browser/cdp/page/{id}`. Start a daemon on a loopback port with a paired device (its listen port and token
// are the ones below), then run with BANDITO_BROWSER_APP_IT=1, BANDITO_BROWSER_APP_URL=ws://127.0.0.1:<port>/v1/rpc
// and BANDITO_BROWSER_APP_TOKEN=<device token>. Skipped in normal runs.

private let appIT = ProcessInfo.processInfo.environment["BANDITO_BROWSER_APP_IT"] == "1"

@MainActor
@Test(.enabled(if: appIT))
func theAppReachesAPageThroughTheDaemonRoutes() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = try #require(env["BANDITO_BROWSER_APP_URL"].flatMap(URL.init(string:)))
    let server = ServerModel(
        config: ServerConfig(name: "it", endpoint: .webSocket(url: url), token: env["BANDITO_BROWSER_APP_TOKEN"]))
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
    let request = try server.browserRequest(path: "/v1/browser/cdp/page/NOSUCHTAB", workspace: nil, socket: true)
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
