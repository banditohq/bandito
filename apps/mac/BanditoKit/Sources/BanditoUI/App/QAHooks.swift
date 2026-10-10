#if DEBUG && os(macOS)
import AppKit
import BanditoKit
import Foundation

// QA hooks for the QA copies of the app (`dev.bandito.mac.debug.qa<n>`, driven by `scripts/qa`). Debug builds only:
// the whole file and its call sites are compiled out of a release build.
//
// Launch arguments (`open --args -qa.<key> <value>`, read from the defaults):
//   qa.server <ws-url>, qa.tokenFile <path>, qa.serverName <name>: the server is added once and selected.
//   qa.filesPath <path>, qa.mode <mode>, qa.sheet <sheet>, qa.window <W>x<H>: applied when the window appears.
// Commands while the app runs: one line sent as the object of a DistributedNotification named
// `dev.bandito.qa.<bundle id>` (see `QACommand`).

/// A window size, `<W>x<H>` in points.
struct QASize: Equatable {
    let width: Int
    let height: Int

    /// `900x600` → 900 by 600. Both sides must be positive whole numbers.
    static func parse(_ text: String) -> QASize? {
        let sides = text.split(separator: "x", omittingEmptySubsequences: false)
        guard sides.count == 2, let width = Int(sides[0]), let height = Int(sides[1]), width > 0, height > 0 else {
            return nil
        }
        return QASize(width: width, height: height)
    }
}

/// A command for a running QA copy: one word, and for some commands one argument (`mode files`, `window 900x600`,
/// `files /Users/me/Project With Spaces`). Anything else is nil, and the app logs it as unknown.
enum QACommand: Equatable {
    case mode(AppMode)
    case sheet(Sheet)
    case dismiss
    case window(QASize)
    case files(path: String)
    case settings
    case onboarding
    case tab(ServerSection)
    /// The workbench of the agent on screen: `details`, `terminal`, `browser`, `changes`, `toggle`, `split`.
    case workbench(String)

    static func parse(_ text: String) -> QACommand? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let word = parts.first.map(String.init) else { return nil }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        switch (word, argument) {
        case ("mode", let name?):
            return AppMode(rawValue: name).map { .mode($0) }
        case ("sheet", let name?):
            return parseSheet(name).map { .sheet($0) }
        case ("dismiss", nil):
            return .dismiss
        case ("window", let size?):
            return QASize.parse(size).map { .window($0) }
        case ("files", let path?) where !path.isEmpty:
            return .files(path: path)
        case ("settings", nil):
            return .settings
        case ("onboarding", nil):
            return .onboarding
        case ("tab", let name?):
            return ServerSection(rawValue: name).map { .tab($0) }
        case ("workbench", let action?) where ["details", "terminal", "browser", "changes", "toggle", "split"].contains(action):
            return .workbench(action)
        default:
            return nil
        }
    }

    /// The sheets a QA run can open.
    static func parseSheet(_ name: String) -> Sheet? {
        switch name {
        case "newAgent": .newAgent
        case "account": .account
        case "addServer": .addServer
        default: nil
        }
    }
}

/// Hooks for the QA copies. Main-actor only: the window, the router and the onboarding model live there.
@MainActor
enum QAHooks {
    private static let defaults = UserDefaults.standard
    private static var started = false
    private static var router: Router?
    private static var onboarding: OnboardingModel?
    private static var observer: NSObjectProtocol?
    private static weak var app: AppModel?

    /// Adds the server named by `-qa.server` and selects it, so the server is in place before the first connect
    /// (called from `AppModel.load`). A server with the same endpoint but another token (a new pairing of the QA
    /// daemon) is replaced: `AppModel.add` takes out the entry with the same endpoint. Without the token file nothing
    /// is added. Only in a QA copy.
    static func addLaunchServer(to model: AppModel) {
        guard QABuild.isRunningQA else { return }
        app = model
        guard let text = defaults.string(forKey: "qa.server"), let url = URL(string: text) else { return }
        let endpoint = ServerEndpoint.webSocket(url: url)
        guard let path = defaults.string(forKey: "qa.tokenFile"), let token = readToken(atPath: path) else {
            NSLog("QA: -qa.tokenFile is missing or empty; the server \(text) was not added")
            return
        }
        if let existing = model.servers.first(where: { $0.config.endpoint == endpoint }), existing.config.token == token {
            return
        }
        model.add(
            ServerConfig(
                name: defaults.string(forKey: "qa.serverName") ?? "QA", endpoint: endpoint, token: token))
    }

    /// Called once when the main window appears: applies the launch arguments and starts listening for commands.
    /// Does nothing outside a QA copy (`QABuild`), so the development build `dev.bandito.mac.debug` gets no hooks.
    static func start(router: Router, onboarding: OnboardingModel) {
        guard QABuild.isRunningQA, !started else { return }
        started = true
        self.router = router
        self.onboarding = onboarding
        applyLaunchArguments(to: router)
        observeCommands()
    }

    /// One command line, from the notification. Unknown commands are logged and ignored.
    static func handle(_ text: String) {
        guard let command = QACommand.parse(text) else {
            NSLog("QA unknown command \(text)")
            return
        }
        guard let router, let onboarding else { return }
        switch command {
        case .mode(let mode):
            router.select(mode: mode)
        case .sheet(let sheet):
            router.sheet = sheet
        case .dismiss:
            router.sheet = nil
        case .window(let size):
            if !resizeMainWindow(size) { NSLog("QA: no main window to resize to \(size.width)x\(size.height)") }
        case .files(let path):
            router.openInFiles(path, isFile: false)
        case .settings:
            WindowActions.showSettings()
        case .onboarding:
            onboarding.replay()
        case .tab(let section):
            router.select(mode: .server)
            router.serverSection = section
        case .workbench(let action):
            runWorkbench(action, router: router)
        }
    }

    /// The workbench of the agent on screen, as its buttons would open it.
    private static func runWorkbench(_ action: String, router: Router) {
        guard let agentID = router.shownAgentID ?? router.selectedAgentID else {
            NSLog("QA: no agent on screen for workbench \(action)")
            return
        }
        switch action {
        case "details": router.showInWorkbench(.details, agentID: agentID)
        case "browser": router.showInWorkbench(.browser, agentID: agentID)
        case "changes": router.showInWorkbench(.changes, agentID: agentID)
        case "toggle": router.toggleWorkbench()
        case "split": router.toggleWorkbenchSplit(agentID: agentID)
        case "terminal":
            #if os(macOS)
            guard let app, let server = app.currentServer, let agent = server.agents.first(where: { $0.id == agentID })
            else { return }
            WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
            #endif
        default: break
        }
    }

    // MARK: launch arguments

    private static func applyLaunchArguments(to router: Router) {
        if let path = defaults.string(forKey: "qa.filesPath") {
            router.filesPath = path
        }
        if let name = defaults.string(forKey: "qa.mode") {
            if let mode = AppMode(rawValue: name) {
                router.select(mode: mode)
            } else {
                NSLog("QA: unknown -qa.mode \(name)")
            }
        }
        if let name = defaults.string(forKey: "qa.sheet") {
            if let sheet = QACommand.parseSheet(name) {
                router.sheet = sheet
            } else {
                NSLog("QA: unknown -qa.sheet \(name)")
            }
        }
        if let text = defaults.string(forKey: "qa.window") {
            guard let size = QASize.parse(text) else {
                NSLog("QA: -qa.window must look like 900x600, got \(text)")
                return
            }
            resizeWhenWindowAppears(size)
        }
    }

    private static func readToken(atPath path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: window

    /// The window may not exist yet when the launch arguments are applied: tries for up to five seconds.
    private static func resizeWhenWindowAppears(_ size: QASize) {
        Task { @MainActor in
            for _ in 0..<50 {
                if resizeMainWindow(size) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSLog("QA: no main window to resize to \(size.width)x\(size.height)")
        }
    }

    /// Sets the content size of the main window and centres it. False when there is no such window yet.
    @discardableResult
    private static func resizeMainWindow(_ size: QASize) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }) else {
            return false
        }
        window.setContentSize(NSSize(width: size.width, height: size.height))
        window.center()
        return true
    }

    // MARK: commands

    private static func observeCommands() {
        guard QABuild.isRunningQA, let bundleID = Bundle.main.bundleIdentifier else { return }
        let name = Notification.Name("dev.bandito.qa.\(bundleID)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { notification in
            let text = notification.object as? String ?? ""
            MainActor.assumeIsolated {
                QAHooks.handle(text)
            }
        }
    }
}
#endif
