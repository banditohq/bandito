import BanditoKit
import BanditoL10n
import Foundation
import ImageIO
import Observation
import SwiftUI

/// What the browser main area shows: a page of the server's browser, or a preview of a port an agent opened.
enum BrowserSelection: Hashable {
    case page(String)
    case preview(Int)
}

/// The state of one server's browser: its status, its tabs, the picture of the current page, and the input
/// that goes to the page. Lives as long as the app keeps the server (see `BrowserStore`).
@MainActor
@Observable
final class BrowserModel {
    let server: ServerModel

    private(set) var status: BrowserStatus?
    private(set) var tabs: [BrowserTab] = []
    /// Preview tabs, in the order they were opened.
    private(set) var previewPorts: [Int] = []
    var selection: BrowserSelection?
    /// The last picture of the page, decoded.
    private(set) var frame: CGImage?
    /// The page size in CSS pixels, from the last frame (what clicks are scaled from).
    private(set) var pageSize: CGSize = .zero
    private(set) var currentURL: String = ""
    private(set) var pageTitle: String = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Shown under the toolbar when the browser cannot be reached.
    private(set) var errorText: String?
    /// True while an agent holds the browser and the person tried to act on the page.
    private(set) var asksToTakeControl = false
    /// Text of the address bar. Edited by the person; reset to the page's URL on navigation.
    var addressText = ""

    private var client: CDPClient?
    private var clientTabID: String?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollTick = 0
    private var lastTouch: Date = .distantPast

    init(server: ServerModel) {
        self.server = server
    }

    /// Whether the server has the browser feature (`server.info.features`).
    var isSupported: Bool { server.supports("browser") }

    /// Whether the agent holds the browser: input is not sent then.
    var isAgentControlling: Bool { status?.controller == .agent }

    /// The person may act on the page: the browser is theirs, or nobody holds it.
    var canInteract: Bool { status?.running == true && !isAgentControlling }

    // MARK: Lifecycle

    /// Starts polling the status and the tabs. Called when the browser view appears.
    func attach() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops polling and closes the page connection. The browser keeps running on the server.
    func detach() {
        pollTask?.cancel()
        pollTask = nil
        Task { await closeClient() }
    }

    /// Starts the browser on the server, then connects to its first page.
    func start() async {
        do {
            status = try await server.browserStart()
            errorText = nil
            await refresh()
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// One poll: the status, the tabs every few polls, and a keep-alive while the browser is on screen.
    func refresh() async {
        guard isSupported else { return }
        do {
            let fresh = try await server.browserStatus()
            status = fresh
            errorText = nil
            guard fresh.running, let port = fresh.cdpPort else {
                await closeClient()
                tabs = []
                return
            }
            pollTick += 1
            if pollTick % 5 == 1 {
                tabs = try await server.browserTabs(cdpPort: port)
            }
            // The page connection follows the page tabs; a preview needs none.
            if client == nil, !isPreviewSelected {
                try await connect(cdpPort: port, tabID: pageTabID)
            }
            if Date().timeIntervalSince(lastTouch) > 60 {
                lastTouch = Date()
                try? await server.browserTouch()
            }
        } catch {
            errorText = Self.describe(error)
        }
    }

    // MARK: Tabs

    private var pageTabID: String? {
        if case .page(let id) = selection { return id }
        return nil
    }

    private var isPreviewSelected: Bool {
        if case .preview = selection { return true }
        return false
    }

    /// Shows a page of the browser.
    func selectPage(_ id: String) async {
        selection = .page(id)
        clientTabID = nil
        await closeClient()
        if let port = status?.cdpPort {
            do {
                try await connect(cdpPort: port, tabID: id)
            } catch {
                errorText = Self.describe(error)
            }
        }
    }

    /// Opens a preview tab for a port an agent started (`bandito-preview://p<port>/`).
    func openPreview(port: Int) {
        if !previewPorts.contains(port) { previewPorts.append(port) }
        selection = .preview(port)
    }

    func closePreview(port: Int) {
        previewPorts.removeAll { $0 == port }
        if selection == .preview(port) { selection = nil }
    }

    /// The URL the preview web view loads for `port`: the server's own loopback for a Mac server,
    /// or the scheme of `PreviewURL` through the authenticated proxy for a remote one.
    func previewURL(port: Int) -> URL? {
        switch server.config.endpoint {
        case .local:
            return URL(string: "http://127.0.0.1:\(port)/")
        case .webSocket:
            return PreviewURL.previewURL(port: port)
        }
    }

    // MARK: Control

    /// Takes the browser from the agent ("Take control", ⌘⇧C).
    func takeControl() async {
        await setControl(.user)
    }

    /// Gives the browser back to the agent ("Give to agent").
    func giveBack() async {
        await setControl(.agent)
    }

    /// Pauses the agent's actions without taking the browser ("Pause").
    func pause() async {
        await setControl(.none)
    }

    private func setControl(_ holder: ControlHolder) async {
        do {
            status = try await server.browserControl(holder)
            asksToTakeControl = false
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// Called when the person clicks or types while an agent holds the browser.
    func noteAgentHasControl() {
        asksToTakeControl = true
    }

    // MARK: Navigation

    /// Opens the typed address. Text without a scheme is taken as `http://`.
    func navigate(to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = trimmed.contains("://") ? trimmed : "http://" + trimmed
        await send(.navigate(url: url))
    }

    func reload() async {
        await send(.reload)
    }

    func goBack() async {
        await goToHistory(offset: -1)
    }

    func goForward() async {
        await goToHistory(offset: 1)
    }

    private func goToHistory(offset: Int) async {
        guard let client else { return }
        do {
            let history = try await client.send(.navigationHistory)
            let index = Int(history["currentIndex"]?.numberValue ?? 0)
            let entries = history["entries"].flatMap { value -> [JSONValue]? in
                if case .array(let items) = value { return items } else { return nil }
            } ?? []
            let target = index + offset
            guard entries.indices.contains(target), let id = entries[target]["id"]?.numberValue else { return }
            _ = try await client.send(.navigateToHistoryEntry(id: Int(id)))
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// The address of the current page as an external link, for "Open on Mac". Nil for localhost, which only the server reaches.
    var externalURL: URL? {
        guard let url = URL(string: currentURL), let host = url.host,
              url.scheme == "http" || url.scheme == "https",
              !["localhost", "127.0.0.1", "::1"].contains(host)
        else { return nil }
        return url
    }

    // MARK: Input

    /// Sends one command to the page, when the person may act. Otherwise asks to take control.
    @discardableResult
    func send(_ command: CDPCommand) async -> Bool {
        guard canInteract else {
            if status?.running == true { noteAgentHasControl() }
            return false
        }
        guard let client else { return false }
        do {
            _ = try await client.send(command)
            return true
        } catch {
            errorText = Self.describe(error)
            return false
        }
    }

    /// The page point under a view point, for a picture of `pageSize` shown in a view of `viewSize`.
    func pagePoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint? {
        PageGeometry.pagePoint(
            x: point.x, y: point.y, viewWidth: viewSize.width, viewHeight: viewSize.height,
            pageWidth: pageSize.width, pageHeight: pageSize.height)
    }

    // MARK: Connection

    private func connect(cdpPort: Int, tabID: String?) async throws {
        await closeClient()
        isLoading = true
        do {
            let (client, tab) = try await server.browserPageClient(cdpPort: cdpPort, tabID: tabID)
            self.client = client
            clientTabID = tab.id
            if selection == nil { selection = .page(tab.id) }
            currentURL = tab.url
            addressText = tab.url
            pageTitle = tab.title
            eventTask = Task { [weak self] in
                for await event in client.events {
                    guard let self else { return }
                    await self.handle(event, client: client)
                }
            }
            _ = try await client.send(.startScreencast(maxWidth: 1280, maxHeight: 800, quality: 70))
        } catch {
            isLoading = false
            throw error
        }
    }

    private func handle(_ event: CDPEvent, client: CDPClient) async {
        switch event.method {
        case "Page.screencastFrame":
            guard let frame = CDP.screencastFrame(from: event.params) else { return }
            // Acknowledge first: the page sends the next frame only after the ack.
            _ = try? await client.send(.ackScreencastFrame(sessionId: frame.sessionId))
            self.frame = Self.decodeJPEG(frame.jpeg) ?? self.frame
            pageSize = CGSize(width: frame.deviceWidth, height: frame.deviceHeight)
            isLoading = false
        case "Page.frameNavigated":
            if let url = event.params["frame"]?["url"]?.string, event.params["frame"]?["parentId"] == nil {
                currentURL = url
                addressText = url
            }
            if let title = event.params["frame"]?["name"]?.string { pageTitle = title }
            await refreshHistoryFlags(client: client)
        case "Page.loadEventFired", "Page.domContentEventFired":
            isLoading = false
        default:
            break
        }
    }

    private func refreshHistoryFlags(client: CDPClient) async {
        guard let history = try? await client.send(.navigationHistory) else { return }
        let index = Int(history["currentIndex"]?.numberValue ?? 0)
        let count: Int = {
            if case .array(let items) = history["entries"] ?? .null { return items.count }
            return 0
        }()
        canGoBack = index > 0
        canGoForward = index < count - 1
    }

    private func closeClient() async {
        eventTask?.cancel()
        eventTask = nil
        let old = client
        client = nil
        clientTabID = nil
        frame = nil
        await old?.close()
    }

    // MARK: Helpers

    /// Decodes a screencast JPEG. Nil when the bytes are not an image.
    static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func describe(_ error: Error) -> String {
        if let rpc = error as? RPCError {
            if rpc.reason == "missing_component" { return L10n.Browser.missingChrome }
            return rpc.message
        }
        if let cdp = error as? CDPError { return cdp.localizedDescription }
        return L10n.Browser.error
    }
}

/// One `BrowserModel` per server, so the sidebar and the main area show the same browser.
@MainActor
final class BrowserStore {
    static let shared = BrowserStore()
    private var models: [UUID: BrowserModel] = [:]

    func model(for server: ServerModel) -> BrowserModel {
        if let model = models[server.id] { return model }
        let model = BrowserModel(server: server)
        models[server.id] = model
        return model
    }
}
