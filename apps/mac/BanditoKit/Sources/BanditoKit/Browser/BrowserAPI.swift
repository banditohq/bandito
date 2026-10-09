import Foundation

// The shared browser of a server (`browser.*`) and the DevTools connection to its pages.

/// Params shared by the `browser.*` and `screen.*` calls: the workspace, when it is not the default.
struct WorkspaceParams: Encodable {
    var workspace: String?
}

extension ServerModel {
    /// Starts the server's browser (or returns the running one).
    public func browserStart(workspace: String? = nil) async throws -> BrowserStatus {
        try await rpc().call("browser.start", WorkspaceParams(workspace: workspace), as: BrowserStatus.self)
    }

    public func browserStatus(workspace: String? = nil) async throws -> BrowserStatus {
        try await rpc().call("browser.status", WorkspaceParams(workspace: workspace), as: BrowserStatus.self)
    }

    public func browserStop(workspace: String? = nil) async throws {
        try await rpc().call("browser.stop", WorkspaceParams(workspace: workspace))
    }

    /// Who may drive the browser now: `.user` takes it from the agent, `.agent` gives it back, `.none` pauses.
    public func browserControl(_ holder: ControlHolder, workspace: String? = nil) async throws -> BrowserStatus {
        struct P: Encodable {
            var workspace: String?
            var holder: ControlHolder
        }
        return try await rpc().call(
            "browser.control", P(workspace: workspace, holder: holder), as: BrowserStatus.self)
    }

    /// Tells the daemon the person is still looking, so an idle browser is not stopped.
    public func browserTouch(workspace: String? = nil) async throws {
        try await rpc().call("browser.touch", WorkspaceParams(workspace: workspace))
    }

    /// The pages of the running browser, from its DevTools HTTP list (`/json/list`).
    /// Uses a one-shot tunnel to the DevTools port: the connection closes after the answer.
    public func browserTabs(cdpPort: Int) async throws -> [BrowserTab] {
        let base = try await forwardOnce(port: cdpPort)
        guard let url = URL(string: "/json/list", relativeTo: base) else { throw CDPError.badMessage }
        var request = URLRequest(url: url)
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CDPError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode([BrowserTab].self, from: data).filter(\.isPage)
    }

    /// A CDP client attached to one page of the running browser: `tabID`, or the first page when nil.
    /// Two one-shot tunnels are used: one for the HTTP list, one for the WebSocket.
    public func browserPageClient(cdpPort: Int, tabID: String? = nil) async throws -> (CDPClient, BrowserTab) {
        let tabs = try await browserTabs(cdpPort: cdpPort)
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first
        guard let tab else { throw CDPError.noPage }
        let local = try await forwardOnce(port: cdpPort)
        guard let url = CDP.pageSocketURL(local: local, pageId: tab.id) else { throw CDPError.badMessage }
        return (CDPClient(socket: URLSessionCDPSocket(url: url)), tab)
    }

    /// A CDP client on the browser-level socket (`browser_ws_path`), for `Target.*` calls.
    public func browserTargetsClient(cdpPort: Int, wsPath: String) async throws -> CDPClient {
        let local = try await forwardOnce(port: cdpPort)
        guard let url = CDP.browserSocketURL(local: local, path: wsPath) else { throw CDPError.badMessage }
        return CDPClient(socket: URLSessionCDPSocket(url: url))
    }
}
