import AppKit
import BanditoKit
import BanditoL10n
import Foundation
import ImageIO
import Observation
import OSLog
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
    private static let log = Logger(subsystem: "dev.bandito.app", category: "browser")

    private(set) var status: BrowserStatus?
    private(set) var tabs: [BrowserTab] = []
    /// Preview tabs, in the order they were opened.
    private(set) var previewPorts: [Int] = []
    var selection: BrowserSelection?
    /// The last picture of the page, decoded. Not observed: a frame comes many times a second, and a view that read it
    /// through the model would redraw the whole tree each time. The picture views listen to `frames` instead (see
    /// `BrowserFrameLayer`); a view that needs only to know whether a picture exists reads `hasFrame`.
    @ObservationIgnored let frames = BrowserFrameStore()
    /// Whether a picture of the page exists. Written only when it changes.
    private(set) var hasFrame = false
    /// The page size in CSS pixels, from the last frame (what clicks are scaled from).
    private(set) var pageSize: CGSize = .zero
    private(set) var currentURL: String = ""
    private(set) var pageTitle: String = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Shown under the toolbar when the browser cannot be reached.
    private(set) var errorText: UserFacingMessage?
    /// True while an agent holds the browser and the person tried to act on the page.
    private(set) var asksToTakeControl = false
    /// Chrome is not on the server, so the browser cannot start. The app offers to install it.
    private(set) var needsChrome = false
    /// Text of the address bar. Edited by the person; reset to the page's URL on navigation.
    var addressText = ""
    /// Shown under the address bar when what was typed cannot be opened (a scheme other than http, https).
    private(set) var addressError: String?

    private var client: CDPClient?
    /// True while the address field has focus: the page's address then does not replace the typed text.
    private(set) var isEditingAddress = false
    /// The id of the page's main frame, from `Page.frameNavigated`. Same-document changes of the address
    /// (`Page.navigatedWithinDocument`) count only for this frame.
    private var mainFrameID: String?
    private var clientTabID: String?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// The views attached now (see `BrowserAttachments`). The polling runs while it is above zero.
    private var attachments = BrowserAttachments()
    /// The picture areas on screen, each with its own size (`PageSurface` views: the panel and Browser mode). The page
    /// follows the newest one; it gets its own size back only when none is left.
    private var pageAreas = BrowserPageAreas()
    private var pollTick = 0
    /// The size the shown page is set to: the picture area on screen. Nil while no page is on screen.
    private var viewport: BrowserViewport?
    /// When the viewport was last sent to the page, and how many times in a row a frame showed the page at another
    /// size anyway (see `resyncViewportIfNeeded`).
    private var viewportSentAt: Date = .distantPast
    private var resyncAttempts = 0
    /// The wait for the picture area to settle before the page is resized.
    static let viewportDelay: Duration = .milliseconds(150)
    /// The task of that wait.
    private var viewportTask: Task<Void, Never>?
    /// The tail of the viewport command queue: each command starts after the one before it has ended.
    private var viewportQueue: Task<Void, Never>?
    /// Wheel events waiting to go to the page, merged and sent at most every 16 ms (see `WheelSender`).
    @ObservationIgnored private var wheel: WheelSender!
    /// Tabs being closed now: a second close of the same tab (⌘W held down) is dropped.
    private var closing: Set<String> = []
    /// True while a title read is waiting for the page's answer. Only one read runs at a time.
    private var titleReadInFlight = false
    /// A title read was asked for while one ran: it runs again once that one ends.
    private var titleReadAgain = false
    private var lastTouch: Date = .distantPast
    /// Reopens the page connection after it drops. Its count restarts once a connection shows an event.
    private var reconnect = BrowserReconnectPolicy()
    /// True after five reconnects in a row failed: the browser is shown as stopped, with a button to start it.
    private(set) var gaveUp = false

    init(server: ServerModel) {
        self.server = server
        wheel = WheelSender { [weak self] batch in await self?.sendWheel(batch) }
    }

    /// Whether the server has the browser feature (`server.info.features`).
    var isSupported: Bool { server.supports("browser") }

    /// Whether the agent holds the browser: input is not sent then.
    var isAgentControlling: Bool { status?.controller == .agent }

    /// The person may act on the page: the browser is theirs, or nobody holds it.
    var canInteract: Bool { status?.running == true && !isAgentControlling }

    // MARK: Lifecycle

    /// Starts polling the status and the tabs. Called when a browser view appears (Browser mode, a workbench tab).
    /// Counted: the views share this model, so the polling runs while any of them is attached.
    func attach() {
        guard attachments.attach() else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops polling and closes the page connection once no view is attached. The browser keeps running on the server.
    func detach() {
        guard attachments.detach() else { return }
        pollTask?.cancel()
        pollTask = nil
        Task { await closeClient() }
    }

    /// Starts the browser on the server, then connects to its first page.
    func start() async {
        gaveUp = false
        reconnect = BrowserReconnectPolicy()
        do {
            status = try await server.browserStart()
            errorText = nil
            needsChrome = false
            await refresh()
        } catch {
            needsChrome = Self.isMissingChrome(error)
            errorText = Self.describe(error)
        }
    }

    /// Opens a new tab on `about:blank` and shows it (⌘T). While an agent drives the browser, it asks to take control
    /// instead. The new tab is made on the browser connection, because `Target.createTarget` is a browser command.
    func newTab() async {
        guard status?.isRelay == true else { return }
        guard canInteract else {
            noteAgentHasControl()
            return
        }
        guard let id = await createBlankTab() else { return }
        tabs = (try? await server.browserTabs()) ?? tabs
        await selectPage(id)
    }

    /// Makes one blank tab on the browser connection and returns its id. Nil (with `errorText` set) on failure.
    private func createBlankTab() async -> String? {
        let browser: CDPClient
        do {
            browser = try await server.browserTargetsClient()
        } catch {
            errorText = Self.describe(error)
            return nil
        }
        defer { Task { await browser.close() } }
        do {
            let result = try await browser.send(.createTarget(url: "about:blank"))
            guard case .object(let object) = result, case .string(let id)? = object["targetId"] else { return nil }
            return id
        } catch {
            errorText = Self.describe(error)
            return nil
        }
    }

    /// How long a tab gets to answer `Target.closeTarget` before the daemon closes it by force.
    static let closeTimeout = 3.0

    /// Closes a tab. The page connection to that tab is let go first: the relay refuses to close a tab another client
    /// holds. The browser is asked to close it and given 3 s; a tab that does not answer, or is refused, is closed by the
    /// daemon (`browser.close_tab`). Either way the tab leaves the list: a hung page never keeps its tab open.
    /// When the shown page is the one closed, the next tab takes its place (see `BrowserTabPolicy`); when none is
    /// left, a blank tab opens. While an agent drives the browser, it asks to take control instead.
    func closeTab(_ id: String) async {
        guard status?.isRelay == true else { return }
        guard canInteract else {
            noteAgentHasControl()
            return
        }
        guard closing.insert(id).inserted else { return }
        defer { closing.remove(id) }
        if clientTabID == id {
            await closeClient()
        }
        if await !askToClose(id, within: Self.closeTimeout) {
            // Old daemons have no forced close: the tab is then dropped from the list and the next poll tells the truth.
            try? await server.browserCloseTab(id)
        }
        let before = tabs.map(\.id)
        let fresh = (try? await server.browserTabs()) ?? tabs
        tabs = fresh.filter { $0.id != id }
        let shown: String? = { if case .page(let shown) = selection { return shown } else { return nil } }()
        switch BrowserTabPolicy.afterClosing(closedID: id, shownID: shown, before: before, remaining: tabs.map(\.id)) {
        case .keep:
            return
        case .show(let next):
            await selectPage(next)
        case .openBlank:
            await closeClient()
            selection = nil
            if let blank = await createBlankTab() {
                tabs = (try? await server.browserTabs()) ?? tabs
                await selectPage(blank)
            }
        }
    }

    /// Asks the browser to close a tab on a connection of its own. False when it refused, failed or did not answer in time.
    private func askToClose(_ id: String, within seconds: Double) async -> Bool {
        let browser: CDPClient
        do {
            browser = try await server.browserTargetsClient()
        } catch {
            return false
        }
        let work = Task { () -> Bool in
            do {
                _ = try await browser.send(.closeTarget(id: id))
                return true
            } catch {
                return false
            }
        }
        let answered = await Self.first(of: work, orElse: false, after: seconds)
        // Closing the connection ends a call that never got its answer, so nothing stays waiting.
        await browser.close()
        return answered
    }

    /// The result of `task`, or `fallback` when it takes longer than `seconds`.
    private static func first<T: Sendable>(of task: Task<T, Never>, orElse fallback: T, after seconds: Double) async -> T {
        await withCheckedContinuation { (resume: CheckedContinuation<T, Never>) in
            let once = ResumeOnceValue(resume)
            Task { once.finish(await task.value) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.finish(fallback)
            }
        }
    }

    /// Closes the shown page (⌘W). Does nothing when a preview is shown: a hidden page tab is never closed by it.
    func closeCurrentTab() async {
        guard case .page(let id) = selection else { return }
        await closeTab(id)
    }

    /// One poll: the status, the tabs every few polls, a reconnect when the page connection is down, and a
    /// keep-alive while the browser is on screen and the app is the active one.
    func refresh() async {
        guard isSupported else { return }
        do {
            let fresh = try await server.browserStatus()
            errorText = nil
            guard fresh.isRelay else {
                status = fresh
                await closeClient()
                tabs = []
                return
            }
            guard !gaveUp else {
                status = .stopped
                return
            }
            status = fresh
            pollTick += 1
            if pollTick % 5 == 1 {
                tabs = try await server.browserTabs()
                fillAddressFromTabs()
            }
            // The page connection follows the page tabs; a preview needs none.
            if client == nil, !isPreviewSelected {
                await reconnectIfDue()
            }
            if Date().timeIntervalSince(lastTouch) > 60, NSApplication.shared.isActive {
                lastTouch = Date()
                try? await server.browserTouch()
            }
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// The address is still empty although the tab has one (the page opened before the connection, or its events were
    /// missed): the tab's own address fills it. A later address is never replaced by the list's, which may be older.
    private func fillAddressFromTabs() {
        guard let clientTabID, let tab = tabs.first(where: { $0.id == clientTabID }),
              let url = BrowserAddressRule.fillFromTab(currentURL: currentURL, tabURL: tab.url)
        else { return }
        movePage(to: url)
        if !tab.title.isEmpty { setPageTitle(tab.title) }
    }

    /// Opens the page connection again if the policy allows it now. After five failures in a row the browser
    /// is shown as stopped, and only Start brings it back.
    private func reconnectIfDue() async {
        switch reconnect.next(at: Date.timeIntervalSinceReferenceDate) {
        case .wait:
            return
        case .giveUp:
            gaveUp = true
            status = .stopped
        case .attempt:
            do {
                try await connect(tabID: pageTabID)
            } catch {
                errorText = Self.describe(error)
            }
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
        guard status?.isRelay == true else { return }
        do {
            try await connect(tabID: id)
        } catch {
            errorText = Self.describe(error)
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
        case .webSocket, .ssh:
            // SSH servers are reached through a local tunnel to the daemon; previews go through its proxy too.
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

    /// Enter in the address field: opens what was typed (an address, or a search) and shows the address it opens.
    /// The view then takes the focus away, which ends the editing (see `addressEditingChanged`).
    func submitAddress() {
        switch BrowserAddress.destination(for: addressText) {
        case .nothing:
            return
        case .refused:
            addressError = L10n.Browser.addressRefused
        case .open(let url):
            addressError = nil
            isEditingAddress = false
            addressText = url
            Task { await send(.navigate(url: url)) }
        }
    }

    /// The person changes the text of the address bar: an error about the text before it no longer applies.
    func addressTextEdited() {
        addressError = nil
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

    /// Scrolls the page: a wheel or trackpad event at a page point. Events are merged and go out at most every 16 ms
    /// (see `WheelBatch`). Dropped quietly while an agent holds the browser: a scroll is not an action worth a banner.
    func scroll(at page: CGPoint, deltaX: Double, deltaY: Double, modifiers: KeyModifiers) {
        guard canInteract, client != nil else {
            Self.log.debug("scroll dropped: canInteract=\(self.canInteract) connected=\(self.client != nil)")
            return
        }
        wheel.add(x: Double(page.x), y: Double(page.y), deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
    }

    private func sendWheel(_ batch: WheelBatch.Pending) async {
        guard canInteract, let client else { return }
        do {
            _ = try await client.send(
                .mouse(
                    type: .mouseWheel, x: batch.x, y: batch.y, button: .none, clickCount: 0,
                    deltaX: batch.deltaX, deltaY: batch.deltaY, modifiers: batch.modifiers))
            Self.log.debug("wheel sent at \(batch.x),\(batch.y) by \(batch.deltaX),\(batch.deltaY)")
        } catch {
            // Not shown to the person (a closed connection is handled by its own path), but kept in the log.
            Self.log.error("wheel failed: \(String(describing: error))")
        }
    }

    private func stopWheel() {
        wheel.stop()
    }

    // MARK: Picture area

    /// The picture area `id` of the shown page changed size, or its window moved to a screen with another scale. The
    /// page follows the newest area after 150 ms without another change, so a window drag sends one resize, not one per
    /// pixel. A view that is not on screen never gets here: it reports only while it is shown.
    func pageAreaChanged(id: UUID, width: Double, height: Double, scale: Double) {
        pageAreas.report(BrowserPageAreas.Area(width: width, height: height, scale: scale), for: id)
        scheduleViewport()
    }

    /// The picture area `id` went away. The page follows the area still on screen (the other view that shows the page
    /// keeps the size it set), and gets its own size back when none is left.
    func pageSurfaceDisappeared(id: UUID) {
        pageAreas.remove(id)
        if pageAreas.isEmpty {
            pageAreaHidden()
        } else {
            scheduleViewport()
        }
    }

    /// Applies the active area's size after the settle delay, restarting the wait on every change.
    private func scheduleViewport() {
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: Self.viewportDelay)
            guard !Task.isCancelled, let self else { return }
            self.applyViewport(self.pageAreas.active)
        }
    }

    /// The picture area is gone: another tab or a preview is shown, or the browser stopped. The page gets its own size back.
    func pageAreaHidden() {
        viewportTask?.cancel()
        viewportTask = nil
        guard viewport != nil else { return }
        viewport = nil
        if let page = client { queueViewport(.clearViewport, on: page) }
    }

    /// Sizes the page to `next` and restarts the screencast with frames of that size. Nil (no usable area) changes nothing.
    private func applyViewport(_ next: BrowserViewport?) {
        guard let next, next != viewport else { return }
        viewport = next
        resyncAttempts = 0
        viewportSentAt = Date()
        guard let client else { return }
        queueViewport(.setViewport(next), on: client)
        // Restarted rather than re-asked: a running screencast may keep its first frame size.
        let box = next.screencastBox
        queueViewport(.stopScreencast, on: client)
        queueViewport(.startScreencast(maxWidth: box.width, maxHeight: box.height, quality: 70), on: client)
    }

    /// Sends one viewport command to `page`, after the viewport commands queued before it. All of them go through
    /// this one queue, so a set and a clear never race. The queue moves on when the page answers or its socket closes.
    private func queueViewport(_ command: CDPCommand, on page: CDPClient) {
        let previous = viewportQueue
        viewportQueue = Task {
            await previous?.value
            _ = try? await page.send(command)
        }
    }

    /// Waits for `task` for at most `seconds`: returns when the task ends or the time is up, whichever is first.
    private static func waitBriefly(_ task: Task<Void, Never>?, seconds: Double) async {
        guard let task else { return }
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(resume)
            Task { await task.value; once.finish() }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.finish() }
        }
    }

    /// Whether the start failed because Chrome is not installed on the server (the install card is shown).
    static func isMissingChrome(_ error: Error) -> Bool {
        (error as? RPCError)?.reason == "missing_component"
    }

    /// The page point under a view point, for a picture of `pageSize` shown in a view of `viewSize`.
    func pagePoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint? {
        PageGeometry.pagePoint(
            x: point.x, y: point.y, viewWidth: viewSize.width, viewHeight: viewSize.height,
            pageWidth: pageSize.width, pageHeight: pageSize.height)
    }

    // MARK: Connection

    private func connect(tabID: String?) async throws {
        await closeClient()
        isLoading = true
        do {
            let (client, tab) = try await server.browserPageClient(tabID: tabID)
            self.client = client
            clientTabID = tab.id
            if selection == nil { selection = .page(tab.id) }
            currentURL = tab.url
            addressText = BrowserAddressRule.shownAddress(tab.url)
            pageTitle = tab.title
            eventTask = Task { [weak self] in
                for await event in client.events {
                    guard let self else { return }
                    await self.handle(event, client: client)
                }
                // The stream ends when the socket closes: the browser stopped, or the link dropped.
                guard let self else { return }
                self.connectionEnded(client)
            }
            // The page takes the size of the picture area (queued: a page that does not answer must not hold the
            // connection), and the screencast asks for frames of that size.
            viewportSentAt = Date()
            if let viewport { queueViewport(.setViewport(viewport), on: client) }
            let box = viewport?.screencastBox ?? BrowserViewport.defaultScreencast
            _ = try await client.send(.startScreencast(maxWidth: box.width, maxHeight: box.height, quality: 70))
            // The page's events (navigation, load) come only after `Page.enable`. The address is read once now, because a
            // page opened before this connection sends no event for it. Not awaited: a page that does not answer must
            // not hold the connection.
            Task { [weak self] in
                _ = try? await client.send(.enablePage)
                await self?.readCurrentAddress(client: client)
                self?.requestTitle(client: client)
            }
        } catch {
            isLoading = false
            throw error
        }
    }

    private func handle(_ event: CDPEvent, client: CDPClient) async {
        // An event from the current connection shows it works: the reconnect count starts over.
        if self.client === client { reconnect.succeeded() }
        switch event.method {
        case "Page.screencastFrame":
            guard let frame = CDP.screencastFrame(from: event.params) else { return }
            // Acknowledge first: the page sends the next frame only after the ack.
            _ = try? await client.send(.ackScreencastFrame(sessionId: frame.sessionId))
            // The decode runs off the main thread; frames are handled one after another, so they stay in order.
            let jpeg = frame.jpeg
            let image = await Task.detached(priority: .userInitiated) { Self.decodeJPEG(jpeg) }.value
            // The page may have changed while the picture was decoded.
            guard self.client === client else { return }
            if let image { setFrame(image) }
            // Written only when the value changes: every write wakes the views that read it.
            let size = CGSize(width: frame.deviceWidth, height: frame.deviceHeight)
            if pageSize != size { pageSize = size }
            if isLoading { isLoading = false }
            resyncViewportIfNeeded(frameSize: size, client: client)
        case "Page.frameNavigated":
            if let frame = event.params["frame"], frame["parentId"] == nil {
                mainFrameID = frame["id"]?.string
                if let url = frame["url"]?.string { movePage(to: url) }
                requestTitle(client: client)
            }
            await refreshHistoryFlags(client: client)
        case "Page.navigatedWithinDocument":
            // Pushed and replaced URLs of single-page sites. Only the main frame counts, and only once it is known.
            if let mainFrameID, event.params["frameId"]?.string == mainFrameID,
               let url = event.params["url"]?.string {
                movePage(to: url)
                requestTitle(client: client)
            }
            await refreshHistoryFlags(client: client)
        case "Page.loadEventFired", "Page.domContentEventFired":
            // Page events are the main frame's. The title is final once the document has loaded.
            isLoading = false
            requestTitle(client: client)
        default:
            break
        }
    }

    /// Keeps the picture and `hasFrame` in step. The picture goes to the views that listen to `frames`.
    private func setFrame(_ image: CGImage?) {
        frames.set(image)
        let has = image != nil
        if hasFrame != has { hasFrame = has }
    }

    /// The page shows another size than the viewport it was given (the override was lost): sends it again, at most
    /// once a second and three times in a row, so a page that cannot take the size does not get a flood.
    private func resyncViewportIfNeeded(frameSize: CGSize, client: CDPClient) {
        guard let viewport else {
            resyncAttempts = 0
            return
        }
        if viewport.matches(frameWidth: Double(frameSize.width), frameHeight: Double(frameSize.height)) {
            resyncAttempts = 0
            return
        }
        guard resyncAttempts < 3, Date().timeIntervalSince(viewportSentAt) > 1 else { return }
        resyncAttempts += 1
        viewportSentAt = Date()
        queueViewport(.setViewport(viewport), on: client)
    }

    /// Reads the address of the current history entry, the page's own truth, and shows it unless it is being typed.
    private func readCurrentAddress(client: CDPClient) async {
        guard let history = try? await client.send(.navigationHistory), self.client === client,
              let url = BrowserAddressRule.currentEntryURL(history)
        else { return }
        movePage(to: url)
    }

    /// The back and forward flags. The address is not read here: the page's own events move it (`movePage`).
    private func refreshHistoryFlags(client: CDPClient) async {
        guard let history = try? await client.send(.navigationHistory) else { return }
        let index = Int(history["currentIndex"]?.numberValue ?? 0)
        let entries = Self.historyEntries(history)
        canGoBack = index > 0
        canGoForward = index < entries.count - 1
    }

    /// Reads the title of the page (`document.title`) in a task of its own: the event loop never waits for the page,
    /// because a JS dialog or a busy page would hold the call for good. One read at a time; an answer later than
    /// one second is dropped, but the read counts as running until the page answers.
    private func requestTitle(client: CDPClient) {
        guard !titleReadInFlight else {
            // The title may have changed since the running read was asked: read once more when it ends.
            titleReadAgain = true
            return
        }
        titleReadInFlight = true
        let deadline = TitleDeadline()
        Task {
            try? await Task.sleep(for: .seconds(1))
            deadline.expire()
        }
        Task { [weak self] in
            let reply = try? await client.send(.evaluate(expression: "document.title"))
            guard let self else { return }
            self.titleReadInFlight = false
            if self.titleReadAgain, self.client === client {
                self.titleReadAgain = false
                self.requestTitle(client: client)
            }
            guard !deadline.expired, self.client === client,
                  let title = reply?["result"]?["value"]?.string
            else { return }
            self.setPageTitle(title)
        }
    }

    /// The title of the shown page. The tab row shows the title of its entry in the list of tabs, so both are kept.
    private func setPageTitle(_ title: String) {
        guard title != pageTitle else { return }
        pageTitle = title
        if let clientTabID, let index = tabs.firstIndex(where: { $0.id == clientTabID }) {
            tabs[index].title = title
        }
    }

    /// The page moved to `url`: the address and, unless it is being typed, the text of the address field follow.
    private func movePage(to url: String) {
        let next = BrowserAddressRule.afterPageMoved(to: url, currentURL: currentURL, typed: addressText, editing: isEditingAddress)
        currentURL = next.currentURL
        addressText = next.typed
        // The tab row in the sidebar names the tab by its address too, so its entry follows the page.
        if let clientTabID, let index = tabs.firstIndex(where: { $0.id == clientTabID }), tabs[index].url != url {
            tabs[index].url = url
        }
    }

    /// Called by the address field when focus comes or goes. When focus leaves, the field shows the page's address.
    func addressEditingChanged(_ editing: Bool) {
        // Already ended by `submitAddress`: the field then keeps the address it opens.
        guard editing != isEditingAddress else { return }
        isEditingAddress = editing
        addressText = BrowserAddressRule.afterEditingEnded(currentURL: currentURL, typed: addressText, editing: editing)
    }

    nonisolated static func historyEntries(_ history: JSONValue) -> [JSONValue] {
        if case .array(let items) = history["entries"] ?? .null { return items }
        return []
    }

    /// The socket closed under us. Drops the connection; the next poll reconnects, under the policy.
    private func connectionEnded(_ ended: CDPClient) {
        guard client === ended else { return }
        stopWheel()
        client = nil
        clientTabID = nil
        mainFrameID = nil
        setFrame(nil)
        isLoading = false
    }

    private func closeClient() async {
        stopWheel()
        eventTask?.cancel()
        eventTask = nil
        let old = client
        client = nil
        clientTabID = nil
        mainFrameID = nil
        setFrame(nil)
        guard let old else { return }
        // The page gets its own size back before its socket closes. A page that does not answer waits one second at most.
        if viewport != nil { queueViewport(.clearViewport, on: old) }
        await Self.waitBriefly(viewportQueue, seconds: 1)
        await old.close()
    }

    // MARK: Helpers

    /// Decodes a screencast JPEG. Nil when the bytes are not an image.
    /// Decoded at once (`ShouldCacheImmediately`), so the drawing later does no decoding. Callable from any thread.
    nonisolated static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    static func describe(_ error: Error) -> UserFacingMessage {
        if let rpc = error as? RPCError, rpc.reason == "missing_component" {
            return UserFacingMessage(text: L10n.Browser.missingChrome)
        }
        return UserFacingError.message(for: error)
    }
}

/// Resumes a continuation once, whichever of two events comes first.
@MainActor
private final class ResumeOnce {
    private var resume: CheckedContinuation<Void, Never>?

    init(_ resume: CheckedContinuation<Void, Never>) {
        self.resume = resume
    }

    func finish() {
        resume?.resume()
        resume = nil
    }
}

/// Resumes a continuation with the first value given; later ones are dropped.
private final class ResumeOnceValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resume: CheckedContinuation<T, Never>?

    init(_ resume: CheckedContinuation<T, Never>) {
        self.resume = resume
    }

    func finish(_ value: T) {
        lock.lock()
        let pending = resume
        resume = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Whether a title read ran out of time: set by the timer, read by the read when it answers.
@MainActor
private final class TitleDeadline {
    private(set) var expired = false

    func expire() {
        expired = true
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

/// What to show after a tab closed. Pure, so the choice is easy to read and test.
enum BrowserTabPolicy {
    enum Outcome: Equatable {
        /// The shown page did not change: nothing to do.
        case keep
        /// The shown page closed: show this tab.
        case show(String)
        /// The shown page closed and no tab is left: open a blank one.
        case openBlank
    }

    /// `before` is the tab ids before the close, `remaining` the ids after it (without `closedID`). The tab that takes
    /// the place of the closed one is the one on its right, or the last one when it was the last of the row.
    static func afterClosing(closedID: String, shownID: String?, before: [String], remaining: [String]) -> Outcome {
        guard shownID == closedID else { return .keep }
        guard !remaining.isEmpty else { return .openBlank }
        let index = before.firstIndex(of: closedID) ?? 0
        return .show(remaining[min(index, remaining.count - 1)])
    }
}

/// How the address follows the page. Pure, so the rules are easy to read and test.
enum BrowserAddressRule {
    struct Fields: Equatable {
        var currentURL: String
        /// The text of the address field.
        var typed: String
    }

    /// The text the address field shows for a page at `url`: the address, or nothing for a new tab.
    static func shownAddress(_ url: String) -> String {
        BrowserTabLabel.isBlank(url) ? "" : url
    }

    /// The page moved to `url`. The field shows the new address, unless the person is typing in it.
    static func afterPageMoved(to url: String, currentURL: String, typed: String, editing: Bool) -> Fields {
        guard url != currentURL else { return Fields(currentURL: currentURL, typed: typed) }
        return Fields(currentURL: url, typed: editing ? typed : shownAddress(url))
    }

    /// The address of a tab fills the field's page address only while that is empty or a blank page. Nil: nothing to change.
    static func fillFromTab(currentURL: String, tabURL: String?) -> String? {
        guard BrowserTabLabel.isBlank(currentURL), let tabURL, !BrowserTabLabel.isBlank(tabURL) else { return nil }
        return tabURL
    }

    /// The address of the current entry of `Page.getNavigationHistory`'s answer. Nil for an empty or odd answer.
    static func currentEntryURL(_ history: JSONValue) -> String? {
        let entries = BrowserModel.historyEntries(history)
        let index = Int(history["currentIndex"]?.numberValue ?? -1)
        guard entries.indices.contains(index), let url = entries[index]["url"]?.string, !url.isEmpty else { return nil }
        return url
    }

    /// Focus left or came to the address field. When it leaves, the field shows the page's address again.
    static func afterEditingEnded(currentURL: String, typed: String, editing: Bool) -> String {
        editing ? typed : shownAddress(currentURL)
    }
}
