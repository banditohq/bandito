import Foundation
import Testing

@testable import BanditoKit

// Manual integration check: a real Chrome with `--remote-debugging-port` must send at least one screencast frame.
// Start Chrome yourself (headless, isolated profile), then run with BANDITO_BROWSER_IT=1 and, when the port
// is not 9333, BANDITO_BROWSER_IT_PORT=<port>. Skipped in normal runs.

@Test(.enabled(if: ProcessInfo.processInfo.environment["BANDITO_BROWSER_IT"] == "1"))
func screencastDeliversAFrameFromChrome() async throws {
    let port = ProcessInfo.processInfo.environment["BANDITO_BROWSER_IT_PORT"].flatMap(Int.init) ?? 9333
    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))

    var listRequest = URLRequest(url: base.appending(path: "json/list"))
    listRequest.setValue("close", forHTTPHeaderField: "Connection")
    let (listData, _) = try await URLSession.shared.data(for: listRequest)
    let pages = try JSONDecoder().decode([BrowserTab].self, from: listData).filter(\.isPage)
    let page = try #require(pages.first)

    let socketURL = try #require(CDP.pageSocketURL(local: base, pageId: page.id))
    let client = CDPClient(socket: URLSessionCDPSocket(url: socketURL))
    _ = try await client.send(.startScreencast(maxWidth: 800, maxHeight: 600, quality: 70))
    // A paint makes Chrome send a frame even on a blank page.
    _ = try await client.send(.navigate(url: "data:text/html,<h1>Bandito screencast check</h1>"))

    let frame = try await withThrowingTaskGroup(of: ScreencastFrame?.self) { group -> ScreencastFrame? in
        group.addTask {
            for await event in client.events where event.method == "Page.screencastFrame" {
                if let frame = CDP.screencastFrame(from: event.params) {
                    _ = try? await client.send(.ackScreencastFrame(sessionId: frame.sessionId))
                    return frame
                }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(20))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }

    let received = try #require(frame)
    #expect(received.jpeg.count > 1000)
    #expect(received.deviceWidth > 0 && received.deviceHeight > 0)
    await client.close()
}
