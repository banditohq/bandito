#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import Observation
import SwiftUI

// The smoothness check (Help menu, with ⌥ held): a window of its own runs every page of the app on demo daemons,
// measures every frame, and shows a table. The person's servers, files and settings are not touched: the demo copy has
// its own models, its own defaults suite, servers that are never saved and transports that never leave the process.
// Telemetry and sounds are off while it runs, and whatever the run wrote to the app's defaults is put back after it.

/// The demo copy of the app: models of its own, two demo servers, forty agents.
@MainActor
final class PerfDemoWorld {
    static let threadRows = 1_500
    static let agentRows = 80
    static let agentCount = 40
    /// Fixed ids: what the app keeps per server (the last agent, the workbench) stays under these.
    static let primaryID = UUID(uuidString: "D3A0D3A0-5EED-4C0C-9F00-0000000000A1")!
    static let secondaryID = UUID(uuidString: "D3A0D3A0-5EED-4C0C-9F00-0000000000B2")!

    let suiteName = "dev.bandito.perfcheck"
    let defaults: UserDefaults
    let app: AppModel
    let router: Router
    let keymap: Keymap
    let gestures: GestureSettings
    let demoStore: DemoStore
    let onboarding: OnboardingModel
    let hub: AccountHub
    let telemetry: TelemetryCenter
    let updates = AppUpdateCenter()
    let focusMode = FocusModeTracker()
    let requests = ScenarioRequests()
    let settingsNavigation = SettingsNavigation()
    let primary: ServerModel
    let secondary: ServerModel
    let primaryTransport: DemoDaemonTransport
    /// The agents of the first server, in the order the scenarios use them.
    let agentIDs: [String]

    init() {
        let suite = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        suite.removePersistentDomain(forName: suiteName)
        defaults = suite
        let ids = (1...Self.agentCount).map { "demo-agent-\($0)" }
        agentIDs = ids
        let first = DemoDaemon.server(
            id: Self.primaryID, name: "Studio", setup: DemoDaemonSetup(agentIDs: ids + [PerfFixtures.threadAgentID], hostname: "studio"))
        let second = DemoDaemon.server(
            id: Self.secondaryID, name: "Build box", setup: DemoDaemonSetup(agentIDs: [], hostname: "build-box"))
        primary = first.0
        primaryTransport = first.1
        secondary = second.0
        app = AppModel(ephemeral: [first.0, second.0], defaults: suite)
        router = Router(defaults: suite)
        keymap = Keymap(defaults: suite)
        gestures = GestureSettings(defaults: suite)
        demoStore = DemoStore(defaults: suite)
        onboarding = OnboardingModel(defaults: suite, hasSavedServers: true)
        hub = AccountHub(keys: NoSecrets(), loadIdentity: { throw PerfProblem(message: "no account in the demo") })
        telemetry = TelemetryCenter()
    }

    /// Connects the demo servers and fills them: the agents with their threads, the long thread of the chat scenarios.
    func start() async {
        await primary.connect()
        await secondary.connect()
        for (index, id) in agentIDs.enumerated() {
            primary.installSyntheticAgent(
                PerfFixtures.agent(id: id, name: PerfFixtures.names[index % PerfFixtures.names.count], index: index),
                items: PerfFixtures.thread(count: Self.agentRows, seed: UInt64(index + 1)))
        }
        primary.installSyntheticAgent(
            PerfFixtures.agent(id: PerfFixtures.threadAgentID, name: "Atlas", index: 5),
            items: PerfFixtures.thread(count: Self.threadRows))
        for index in 0..<6 {
            secondary.installSyntheticAgent(
                PerfFixtures.agent(id: "demo-build-\(index)", name: PerfFixtures.names[(index + 20) % 40], index: index),
                items: PerfFixtures.thread(count: 40, seed: UInt64(100 + index)))
        }
        router.select(mode: .team)
        router.selectedAgentID = agentIDs.first
    }

    /// The demo browser: eight tabs with a picture each (the demo daemon has no Chrome).
    func showDemoBrowser() {
        let model = BrowserStore.shared.model(for: primary)
        guard model.tabs.isEmpty else { return }
        let sites = ["docs", "dashboard", "issues", "preview", "status", "search", "logs", "settings"]
        var tabs: [BrowserTab] = []
        var pictures: [String: CGImage] = [:]
        for (index, site) in sites.enumerated() {
            let id = "demo-tab-\(index)"
            tabs.append(BrowserTab(id: id, title: site.capitalized, url: "https://\(site).example.com/"))
            if let picture = Self.picture(index: index) { pictures[id] = picture }
        }
        model.showDemo(tabs: tabs, pictures: pictures)
    }

    /// A page-sized picture with a header band and rows of text-like bars, one colour per tab.
    private static func picture(index: Int) -> CGImage? {
        let width = 1280
        let height = 800
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let hue = CGFloat(index) / 8
        context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: height - 90, width: width, height: 90))
        context.setFillColor(NSColor(calibratedWhite: 0.8, alpha: 1).cgColor)
        for row in 0..<24 {
            let y = height - 140 - row * 26
            context.fill(CGRect(x: 80, y: y, width: 400 + (row * 97 + index * 31) % 700, height: 12))
        }
        return context.makeImage()
    }

    /// Disconnects the demo servers and forgets what the run left in shared stores.
    func tearDown() async {
        primary.removeSyntheticAgents()
        secondary.removeSyntheticAgents()
        await primary.disconnect()
        await secondary.disconnect()
        BrowserStore.shared.forget(serverID: Self.primaryID)
        BrowserStore.shared.forget(serverID: Self.secondaryID)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A secret store with nothing in it: the demo copy is signed out and asks the Keychain for nothing.
private struct NoSecrets: SecretStore {
    func load(account: String) throws -> Data? { nil }
    func save(_ data: Data?, account: String) throws {}
}

/// Puts back what a run wrote to the app's own defaults (a view of the demo copy may save a choice to `.standard`,
/// such as the Market tab): the keys that changed are restored, the keys that appeared are removed.
@MainActor
struct DefaultsGuard {
    private let domain: String?
    private let before: [String: Any]

    init() {
        domain = Bundle.main.bundleIdentifier
        before = domain.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
    }

    func restore() {
        guard let domain else { return }
        let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        for (key, value) in after {
            if let old = before[key] {
                if !(old as AnyObject).isEqual(value) { UserDefaults.standard.set(old, forKey: key) }
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        for (key, value) in before where after[key] == nil {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

/// The state of the check, for its window.
@MainActor
@Observable
final class PerfCheckRun {
    enum Phase: Equatable {
        case preparing
        case running(index: Int, scenario: PerfScenario)
        case done
    }

    var phase: Phase = .preparing
    var results: [PerfReport] = []
    /// The window shows the Settings pages instead of the app (the Settings scenario).
    var showsSettings = false
    var screenFPS = 60
    var copied = false
}

/// The smoothness check: its window, the run, the results.
@MainActor
enum PerfCheck {
    /// The identifier of the check's window: the app's "main window" helpers leave it alone.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("dev.bandito.perf-check")
    private static var controller: PerfCheckWindowController?

    /// Opens the window and runs every page (the menu item). A window that is open comes to the front.
    static func open() {
        if let controller {
            controller.showWindow(nil)
            NSApp.activate()
            return
        }
        let made = PerfCheckWindowController()
        controller = made
        made.onClose = { controller = nil }
        made.showWindow(nil)
        NSApp.activate()
        made.window?.makeKeyAndOrderFront(nil)
        made.runAll()
    }

    #if DEBUG
    /// QA: runs `scenarios` in the check's window (opened for it), writes one JSON file per scenario and, for a run of
    /// several, `perf-check.json` with all of them; leaves the window open.
    static func runQA(_ scenarios: [PerfScenario], summaryPath: String?, singlePath: String?) {
        let target: PerfCheckWindowController
        if let controller {
            target = controller
        } else {
            target = PerfCheckWindowController()
            controller = target
            target.onClose = { controller = nil }
            target.showWindow(nil)
        }
        NSApp.activate()
        target.window?.makeKeyAndOrderFront(nil)
        target.run(scenarios) { reports in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for report in reports {
                let url = PerfReport.destination(
                    scenario: report.scenario, path: scenarios.count == 1 ? singlePath : nil)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? encoder.encode(report) { try? data.write(to: url, options: .atomic) }
            }
            if scenarios.count > 1, let data = try? encoder.encode(reports) {
                let url = PerfReport.destination(scenario: "check", path: summaryPath)
                try? data.write(to: url, options: .atomic)
            }
            NSLog("QA perf done: \(reports.map(\.scenario).joined(separator: ","))")
        }
    }
    #endif

    /// The results as text, for the clipboard: one line per page and the verdict.
    static func text(_ reports: [PerfReport], fps: Int) -> String {
        var lines = [L10n.PerfCheck.title, L10n.PerfCheck.screen(fps: "\(fps)"), L10n.PerfCheck.target, ""]
        lines.append(
            [
                L10n.PerfCheck.Column.page, L10n.PerfCheck.Column.frame, L10n.PerfCheck.Column.over8,
                L10n.PerfCheck.Column.over16, L10n.PerfCheck.Column.worst, L10n.PerfCheck.Column.freezes,
                L10n.PerfCheck.Column.target,
            ].joined(separator: "\t"))
        for report in reports {
            let row = PerfCheckRow(report)
            lines.append([row.page, row.frame, row.over8, row.over16, row.worst, row.freezes, row.verdict].joined(separator: "\t"))
        }
        lines.append("")
        lines.append(PerfCheckRow.summary(reports))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        lines.append("Bandito \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        return lines.joined(separator: "\n")
    }
}

/// One row of the results table, as text.
struct PerfCheckRow {
    let page: String
    let frame: String
    let over8: String
    let over16: String
    let worst: String
    let freezes: String
    let verdict: String
    let meets: Bool
    let failed: Bool

    init(_ report: PerfReport) {
        page = PerfScenario(rawValue: report.scenario)?.title ?? report.scenario
        let stats = report.frames
        frame = L10n.PerfCheck.ms(value: Self.number(stats.p95Ms))
        over8 = L10n.PerfCheck.percent(value: Self.number(stats.shareOver8Ms * 100))
        over16 = L10n.PerfCheck.percent(value: Self.number(stats.shareOver16Ms * 100))
        worst = L10n.PerfCheck.ms(value: Self.number(stats.worstFrameMs))
        freezes = "\(stats.stretchesOver100Ms)"
        failed = report.error != nil
        meets = report.meetsTarget
        verdict = failed ? L10n.PerfCheck.failed : (meets ? L10n.PerfCheck.met : L10n.PerfCheck.missed)
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }

    static func summary(_ reports: [PerfReport]) -> String {
        let missing = reports.filter { !$0.meetsTarget }.count
        return missing == 0 ? L10n.PerfCheck.Summary.all : L10n.PerfCheck.Summary.some(count: missing)
    }
}

/// The check's window: the demo copy of the app while it runs, the table after.
@MainActor
final class PerfCheckWindowController: NSWindowController, NSWindowDelegate {
    let world = PerfDemoWorld()
    let state = PerfCheckRun()
    var onClose: (() -> Void)?
    private var task: Task<Void, Never>?
    private var started = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.identifier = PerfCheck.windowIdentifier
        window.title = L10n.PerfCheck.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.backgroundColor = NSColor(srgbRed: 0.071, green: 0.063, blue: 0.055, alpha: 1)
        window.contentMinSize = NSSize(width: 900, height: 600)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PerfCheckRoot(world: world, state: state, onAgain: { [weak self] in
            self?.runAll()
        }))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Every page, for the menu item and "Run again".
    func runAll() {
        run(PerfScenario.allCases) { _ in }
    }

    func run(_ scenarios: [PerfScenario], then done: @escaping ([PerfReport]) -> Void) {
        guard task == nil, let window, let content = window.contentView else { return }
        task = Task { @MainActor in
            let guardian = DefaultsGuard()
            SoundPlayer.isMuted = true
            Telemetry.isPaused = true
            defer {
                SoundPlayer.isMuted = false
                Telemetry.isPaused = false
                guardian.restore()
                task = nil
            }
            state.phase = .preparing
            state.results = []
            state.copied = false
            if !started {
                started = true
                await world.start()
            }
            let recorder = FrameRecorder(view: content)
            defer { recorder.invalidate() }
            // A moment for the first layout and the demo daemons' first answers.
            await recorder.frames(60)
            var reports: [PerfReport] = []
            for (index, scenario) in scenarios.enumerated() {
                if Task.isCancelled { break }
                state.phase = .running(index: index, scenario: scenario)
                let stage = PerfStage(
                    window: window, world: world, recorder: recorder,
                    showSettings: { [state] on in if state.showsSettings != on { state.showsSettings = on } })
                let report = await PerfScenarios.run(scenario, on: stage)
                reports.append(report)
                state.results = reports
            }
            state.showsSettings = false
            state.screenFPS = window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
            state.phase = .done
            done(reports)
        }
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        let world = self.world
        Task { @MainActor in
            await world.tearDown()
        }
        onClose?()
    }
}

/// The window's content: the demo copy of the app, with the progress at the bottom, or the results.
private struct PerfCheckRoot: View {
    let world: PerfDemoWorld
    @Bindable var state: PerfCheckRun
    var onAgain: () -> Void

    var body: some View {
        ZStack {
            demo
                // The run drives the pages itself; a stray click would change what is measured.
                .allowsHitTesting(false)
                .opacity(state.phase == .done ? 0 : 1)
            if state.phase == .done {
                PerfCheckResults(state: state, onAgain: onAgain)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if case .running(let index, let scenario) = state.phase {
                PerfCheckProgress(title: scenario.title, index: index + 1, total: PerfScenario.allCases.count)
                    .padding(.bottom, 14)
            } else if state.phase == .preparing {
                PerfCheckProgress(title: L10n.PerfCheck.title, index: 0, total: PerfScenario.allCases.count)
                    .padding(.bottom, 14)
            }
        }
        .windowRoot(minWidth: 900, minHeight: 600)
        .background(Color.Bandito.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var demo: some View {
        Group {
            if state.showsSettings {
                SettingsWindow()
            } else {
                MainWindow()
            }
        }
        .font(BanditoFont.text(size: 13))
        .environment(world.app)
        .environment(world.router)
        .environment(world.keymap)
        .environment(world.gestures)
        .environment(world.demoStore)
        .environment(world.onboarding)
        .environment(world.hub)
        .environment(world.telemetry)
        .environment(world.updates)
        .environment(\.focusMode, world.focusMode)
        .environment(\.scenarioRequests, world.requests)
        .environment(\.settingsNavigation, world.settingsNavigation)
    }
}

/// The pill at the bottom while the check runs: which page, and how far.
private struct PerfCheckProgress: View {
    let title: String
    let index: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(index > 0 ? L10n.PerfCheck.running(page: title) : title)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            if index > 0 {
                Text(L10n.PerfCheck.progress(index: "\(index)", total: "\(total)"))
                    .font(BanditoFont.mono(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.Bandito.surface2, in: Capsule())
        .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

/// The table of the results, the verdict and the buttons.
private struct PerfCheckResults: View {
    @Bindable var state: PerfCheckRun
    var onAgain: () -> Void

    private var rows: [PerfCheckRow] { state.results.map(PerfCheckRow.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.PerfCheck.title)
                        .font(BanditoFont.display(size: 20, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    Text(L10n.PerfCheck.intro)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.PerfCheck.screen(fps: "\(state.screenFPS)") + " · " + L10n.PerfCheck.target)
                        .font(BanditoFont.text(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                table
                    .banditoCard()
                Text(PerfCheckRow.summary(state.results))
                    .font(BanditoFont.text(size: 14, weight: 600))
                    .foregroundStyle(rows.allSatisfy(\.meets) ? Color.Bandito.ok : Color.Bandito.danger)
                ActionRow {
                    Button(state.copied ? L10n.PerfCheck.copied : L10n.PerfCheck.copy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            PerfCheck.text(state.results, fps: state.screenFPS), forType: .string)
                        state.copied = true
                    }
                    .banditoButton(.signal())
                    Button(L10n.PerfCheck.again, action: onAgain)
                        .banditoButton(.quiet())
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.Bandito.bg)
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                header(L10n.PerfCheck.Column.page)
                header(L10n.PerfCheck.Column.frame)
                header(L10n.PerfCheck.Column.over8)
                header(L10n.PerfCheck.Column.over16)
                header(L10n.PerfCheck.Column.worst)
                header(L10n.PerfCheck.Column.freezes)
                header(L10n.PerfCheck.Column.target)
            }
            .padding(.vertical, 10)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(row.page)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                    cell(row.frame)
                    cell(row.over8)
                    cell(row.over16)
                    cell(row.worst)
                    cell(row.freezes)
                    Text(row.verdict)
                        .font(BanditoFont.text(size: 13, weight: 600))
                        .foregroundStyle(row.meets ? Color.Bandito.ok : Color.Bandito.danger)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 11.5, weight: 600))
            .foregroundStyle(Color.Bandito.text3)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.mono(size: 12.5))
            .foregroundStyle(Color.Bandito.text2)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Puts "Smoothness check…" in the Help menu as the ⌥ alternate of the item before it. SwiftUI builds the menu, so
/// the item is added again whenever a menu opens and finds it missing.
@MainActor
enum PerfCheckMenu {
    private static var observer: NSObjectProtocol?
    private static let marker = "dev.bandito.perf-check.menu"

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ensureItem() }
        }
        ensureItem()
    }

    private static func ensureItem() {
        guard let help = NSApp.helpMenu ?? NSApp.mainMenu?.items.last?.submenu else { return }
        guard !help.items.contains(where: { ($0.representedObject as? String) == marker }) else { return }
        guard let anchor = help.items.lastIndex(where: { !$0.isSeparatorItem && $0.keyEquivalent.isEmpty }) else {
            return
        }
        let item = NSMenuItem(
            title: L10n.PerfCheck.menu, action: #selector(PerfCheckMenuTarget.open), keyEquivalent: "")
        item.target = PerfCheckMenuTarget.shared
        item.keyEquivalentModifierMask = [.option]
        item.isAlternate = true
        item.representedObject = marker
        help.insertItem(item, at: anchor + 1)
    }
}

/// The target of the menu item.
@MainActor
final class PerfCheckMenuTarget: NSObject {
    static let shared = PerfCheckMenuTarget()

    @objc func open() { PerfCheck.open() }
}
#endif
