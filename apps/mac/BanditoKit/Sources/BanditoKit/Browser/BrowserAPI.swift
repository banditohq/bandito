import Foundation

// The shared browser of a server (`browser.*`) and its DevTools sessions over `/v1/browser/*`.

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

    /// The pages of the running browser (`GET /v1/browser/tabs`). Throws `CDPError.browserNotRunning` (409)
    /// when there is no browser.
    public func browserTabs(workspace: String? = nil) async throws -> [BrowserTab] {
        let request = try await daemonRequest(
            path: "/v1/browser/tabs", query: BrowserRoute.query(workspace: workspace), socket: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CDPError.routeError(status: status) }
        return try JSONDecoder().decode([BrowserTab].self, from: data).filter(\.isPage)
    }

    /// A CDP session on one page (`WS /v1/browser/cdp/page/{id}`): `tabID`, or the first page when nil.
    /// A running browser with no page gets a blank one first. Throws `CDPError.noSuchTab` (404) when the
    /// tab has closed.
    public func browserPageClient(tabID: String? = nil, workspace: String? = nil) async throws -> (CDPClient, BrowserTab) {
        var tabs = try await browserTabs(workspace: workspace)
        if tabs.isEmpty {
            try await createBlankTab(workspace: workspace)
            tabs = try await browserTabs(workspace: workspace)
        }
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first
        guard let tab else { throw CDPError.noPage }
        guard BrowserRoute.isValidTargetID(tab.id) else { throw CDPError.badMessage }
        let request = try await daemonRequest(
            path: "/v1/browser/cdp/page/\(tab.id)", query: BrowserRoute.query(workspace: workspace), socket: true)
        let socket = try await URLSessionCDPSocket.open(request: request)
        return (CDPClient(socket: socket), tab)
    }

    /// The browser-level CDP session (`WS /v1/browser/cdp`), for `Target.*` calls such as making a tab.
    public func browserTargetsClient(workspace: String? = nil) async throws -> CDPClient {
        let request = try await daemonRequest(
            path: "/v1/browser/cdp", query: BrowserRoute.query(workspace: workspace), socket: true)
        return CDPClient(socket: try await URLSessionCDPSocket.open(request: request))
    }

    /// Opens `about:blank` in a new tab, on the browser-level session (`Target.createTarget` is a browser command).
    func createBlankTab(workspace: String? = nil) async throws {
        let browser = try await browserTargetsClient(workspace: workspace)
        do {
            _ = try await browser.send(.createTarget(url: "about:blank"))
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }
}
