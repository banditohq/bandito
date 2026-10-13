#if os(macOS) && DEBUG
import AppKit
import BanditoDesign
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// The first-run flow on a demo daemon that lives in memory (no network, no Keychain, no `~/.bandito`), in a window
/// nobody sees: borderless, off every screen, see-through, deaf to the pointer, never ordered in. The pictures come
/// from `cacheDisplay`. Steps are driven by hand (the run loop for a moment, then a layout and a display), so a count
/// depends on what the app builds, not on time.
@MainActor
final class OnboardingWorld {
    let suite = "onboarding-world-\(UUID().uuidString)"
    let defaults: UserDefaults
    let server: ServerModel
    let transport: DemoDaemonTransport
    let app: AppModel
    let router: Router
    let keymap: Keymap
    let gestures: GestureSettings
    let demoStore: DemoStore
    let onboarding: OnboardingModel
    let hub: AccountHub
    let telemetry = TelemetryCenter()
    let updates = AppUpdateCenter()
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private let dark: Bool
    private(set) var session: OnboardingSession?

    init(step: OnboardingStep, card: Int = 0, dark: Bool = true, size: CGSize = CGSize(width: 1100, height: 700)) {
        self.dark = dark
        let suite = UserDefaults(suiteName: self.suite) ?? UserDefaults()
        suite.removePersistentDomain(forName: self.suite)
        defaults = suite
        defaults.set(step.rawValue, forKey: OnboardingModel.stepKey)
        defaults.set(card, forKey: OnboardingModel.cardKey)
        let made = DemoDaemon.server(
            id: UUID(), name: "Studio", setup: DemoDaemonSetup(agentIDs: [], hostname: "studio"))
        server = made.0
        transport = made.1
        app = AppModel(ephemeral: [made.0], defaults: suite)
        router = Router(defaults: suite)
        keymap = Keymap(defaults: suite)
        gestures = GestureSettings(defaults: suite)
        demoStore = DemoStore(defaults: suite)
        // The steps after the server resume only when a server is saved; the picture of the server step has none yet.
        onboarding = OnboardingModel(defaults: suite, hasSavedServers: step.needsServer)
        hub = AccountHub(keys: MemorySecretStore(), loadIdentity: { throw URLError(.notConnectedToInternet) })
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(origin: .zero, size: size)
    }

    /// Everything that waits for the demo daemon, done before the window has a view. A view that is alive while the
    /// test waits is drawn by the app's own run loop, outside the test, and would read the system language instead of
    /// the one the test pinned (`PinnedLanguage` is task-local). So: connect, read what the server steps read, and
    /// only then `show()`, which draws in the test's own turn.
    func prepare(readServerSteps: Bool) async {
        _ = BanditoFont.registerBundledFonts()
        await server.connect()
        guard readServerSteps else { return }
        let session = OnboardingSession(
            server: server, createdIDs: { [onboarding] in onboarding.createdAgentIDs },
            noteCreated: { [onboarding] in onboarding.rememberCreated($0) })
        await session.subscriptions.checkAgain()
        await session.crew.start()
        // The tasks the models started (the folder that is free) finish while no view is alive.
        try? await Task.sleep(for: .milliseconds(400))
        self.session = session
    }

    /// An agent on the demo server, remembered by the flow as the crew's first (the first-task step sends to it).
    func hireForge() async throws {
        let forge = try await server.createAgent(
            NewAgent(name: "Forge", runtime: .claude, cwd: "/home/studio/projects/web"))
        onboarding.rememberFirstAgent(forge.id, team: "web-project")
    }

    /// Puts the flow in the window and draws it, all inside the caller's turn (no suspension).
    func show() {
        host.rootView = AnyView(
            OnboardingFlow(session: session)
                .font(BanditoFont.text(size: 13))
                .environment(app)
                .environment(router)
                .environment(keymap)
                .environment(gestures)
                .environment(demoStore)
                .environment(onboarding)
                .environment(hub)
                .environment(telemetry)
                .environment(updates)
                .environment(\.firstFitRememberedFirst, false)
                .preferredColorScheme(dark ? .dark : .light))
        window.contentView = host
        spin()
    }

    func stop() async {
        window.contentView = nil
        await server.disconnect()
        defaults.removePersistentDomain(forName: suite)
    }

    /// `rounds` turns of the run loop with a layout and a display after each: tasks the views started finish and their
    /// changes are drawn. Never suspends, so the caller's task (and its pinned language) stays the one that draws. Few
    /// rounds, because the main thread is held for all of them: other tests wait for it (one that times two checks
    /// failed when this held it for two seconds).
    func spin(_ rounds: Int = 12) {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }

    /// The counters during `body` (and the settling after it), by name.
    func count(_ body: () -> Void) -> [String: Int] {
        PerfCounters.reset()
        PerfCounters.counting = true
        defer { PerfCounters.counting = false }
        body()
        spin()
        return PerfCounters.snapshot()
    }

    /// The picture of the window now, at two pixels a point.
    func png(_ name: String) throws -> URL {
        let bounds = host.bounds
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            "a bitmap for \(name)")
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]), "a PNG for \(name)")
        let url = SnapshotSupport.outDir.appending(path: "\(name).png")
        try data.write(to: url)
        return url
    }
}
#endif
