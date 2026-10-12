import AppKit
import BanditoDesign
@testable import BanditoKit
import SwiftUI

@testable import BanditoL10n
@testable import BanditoUI

/// What one audited view needs to be built: models on private defaults and private secret storage, so building a view
/// never reaches the person's own Bandito (`dev.bandito.mac` defaults, Keychain, `~/.bandito`, the daemon).
@MainActor
final class AuditEnvironment {
    let suite = "layout-audit-\(UUID().uuidString)"
    let defaults: UserDefaults
    let app: AppModel
    let router = Router()
    let demo: DemoStore
    let keymap: Keymap
    let gestures: GestureSettings
    let hub: AccountHub
    let telemetry: TelemetryCenter
    let updates = AppUpdateCenter()
    /// The first-run flow; a case picks its step with `showOnboarding(_:)`.
    var onboarding: OnboardingModel
    /// The first server of `app`, never connected: a view that asks it for something gets "not connected" at once.
    let server: ServerModel

    /// With `signedIn` the account hub holds a session (no network, no real Keychain: a memory store, and no device key
    /// can be made, so a view that asks the hub for a client fails at once like an offline Mac).
    init(signedIn: Bool = false) {
        let keys = MemorySecretStore()
        if signedIn {
            let session = Session(
                token: "audit", user: AccountUser(id: "u1", email: "maria@example.com", name: "Maria", githubLogin: "maria"),
                device: DeviceRef(id: "d1", approved: true))
            try? keys.save(try? JSONEncoder().encode(session), account: AccountClient.sessionAccount)
        }
        hub = AccountHub(keys: keys, loadIdentity: { throw URLError(.notConnectedToInternet) })
        defaults = UserDefaults(suiteName: suite)!
        // Two saved servers (a long name on purpose), read by `AppModel` from the private defaults. `app.add` is not
        // used: it writes the device token to the Keychain and connects.
        let configs = [
            ServerConfig(
                name: "Production server in the Frankfurt datacenter",
                endpoint: .webSocket(url: URL(string: "wss://bandito-production-frankfurt.example.internal:7878/v1/rpc")!)),
            ServerConfig(name: "This Mac", endpoint: .defaultLocal, isThisMac: true),
        ]
        defaults.set(try? JSONEncoder().encode(configs), forKey: "servers.v1")
        let model = AppModel(defaults: defaults)
        app = model
        server = model.servers[0]
        demo = DemoStore(defaults: defaults)
        keymap = Keymap(defaults: defaults)
        gestures = GestureSettings(defaults: defaults)
        onboarding = OnboardingModel(defaults: defaults, hasSavedServers: false)
        telemetry = TelemetryCenter(
            telemetry: Telemetry(
                defaults: defaults, http: OfflineHTTP(), baseURL: URL(string: "https://audit.invalid")!))
    }

    /// The first-run flow, in front, at `step`.
    func showOnboarding(_ step: OnboardingStep) {
        defaults.set(step.rawValue, forKey: OnboardingModel.stepKey)
        onboarding = OnboardingModel(defaults: defaults, hasSavedServers: false)
    }

    /// The server tells what it can: `features` are the capabilities `server.supports(...)` answers.
    func serverInfo(version: String = "0.1.9", features: [String]) {
        let json = ##"{"version":"\##(version)","hostname":"bandito-production-frankfurt-01","os":"linux","arch":"x86_64","started_at":1790000000000,"last_seq":0,"features":[\##(features.map { "\"\($0)\"" }.joined(separator: ","))]}"##
        server.info = try? RPCClient.decoder.decode(DaemonInfo.self, from: Data(json.utf8))
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    /// The environment every audited view gets.
    func wrap<V: View>(_ view: V) -> some View {
        view
            .environment(app)
            .environment(router)
            .environment(demo)
            .environment(keymap)
            .environment(gestures)
            .environment(hub)
            .environment(telemetry)
            .environment(updates)
            .environment(onboarding)
            // One pass, no second frame: a remembered `FirstFit` choice for another width would stand.
            .environment(\.firstFitRememberedFirst, false)
    }
}

struct OfflineHTTP: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

/// One view to audit: its name, the narrowest width its container can have, and how to build it.
struct AuditCase {
    let name: String
    /// The narrowest width of the container (sheet width, window minimum, right column of Settings at the minimum).
    let width: CGFloat
    /// A fixed height (for a container with one: a sheet with `.frame(height:)`); nil = as tall as the content.
    var height: CGFloat?
    /// The view sets its own width (`.frame(width:)`); the case then shows it as it is. Otherwise `width` is proposed.
    var selfSized = false
    /// The view is a page that scrolls (Settings): it is drawn in a tall box so all of it shows, and the empty rest is cut.
    var scrolls = false
    /// The account hub holds a session (a signed-in person).
    var signedIn = false
    /// The view paints a background beyond its box on purpose (the first-run flow's full-window art): no spill check.
    var bleeds = false
    let make: @MainActor (AuditEnvironment) -> AnyView
}

struct AuditFinding: CustomStringConvertible {
    let name: String
    let language: String
    let requiredWidth: CGFloat
    let width: CGFloat
    let spilledPixels: Int
    var description: String {
        "\(language)/\(name): needs \(Int(requiredWidth.rounded())) pt of \(Int(width)), \(spilledPixels) px outside the box"
    }
    var isProblem: Bool { requiredWidth > width + 0.5 || spilledPixels > 0 }
}

/// Reads the width a view asks for when it is offered `width` (more than that = it does not fit).
private struct WidthProbe: Layout {
    final class Box: @unchecked Sendable {
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
    let box: Box
    let offered: CGFloat
    let fixedHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let size = first.sizeThatFits(ProposedViewSize(width: offered, height: fixedHeight))
        box.width = size.width
        box.height = size.height
        return CGSize(width: offered, height: fixedHeight ?? size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: offered, height: fixedHeight ?? bounds.height))
    }
}

@MainActor
enum LayoutAudit {
    /// Where the pictures go; nil (variable not set) = the audit is skipped.
    nonisolated static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["LAYOUT_AUDIT_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The margin around the box, painted magenta: anything of the view that lands there spilled out of its container.
    private static let margin: CGFloat = 40
    private static let tallest: CGFloat = 2600
    private static let flag = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    static func audit(_ item: AuditCase, language: String, into directory: URL?) -> AuditFinding {
        let env = AuditEnvironment(signedIn: item.signedIn)
        defer { env.cleanUp() }
        let content = env.wrap(item.make(env)).environment(\.colorScheme, .dark)

        // Pass 1: how wide and how tall the view wants to be when offered the container's width.
        let box = WidthProbe.Box()
        let measured = NSHostingView(
            rootView: WidthProbe(box: box, offered: item.width, fixedHeight: item.height) { content })
        measured.frame = CGRect(x: 0, y: 0, width: item.width, height: item.height ?? tallest)
        measured.layoutSubtreeIfNeeded()
        let height = item.scrolls ? tallest : min(item.height ?? max(box.height, 40), tallest)

        // Pass 2: the picture, the box in the middle of a flagged margin.
        let canvas = CGSize(width: item.width + 2 * margin, height: height + 2 * margin)
        let inner = CGSize(width: item.width, height: height)
        let picture = ZStack {
            Color(nsColor: flag)
            ZStack(alignment: .topLeading) {
                Color.Bandito.surface1
                content.frame(width: inner.width, height: inner.height, alignment: .topLeading)
            }
            .frame(width: inner.width, height: inner.height)
        }
        .frame(width: canvas.width, height: canvas.height)
        let host = NSHostingView(rootView: picture)
        host.frame = CGRect(origin: .zero, size: canvas)
        // No window: a view in a window runs its `.task` and `.onAppear` (network, notification centre, the daemon).
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()

        var spilled = 0
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            spilled = item.bleeds ? 0 : countSpilledPixels(rep, margin: Int(margin * CGFloat(rep.pixelsWide) / canvas.width))
            var shown = rep
            if item.scrolls { shown = trimmed(rep, canvasHeight: canvas.height) }
            if let directory, let png = shown.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appending(path: "\(language)-\(item.name).png"))
            }
        }
        return AuditFinding(
            name: item.name, language: language, requiredWidth: box.width, width: item.width, spilledPixels: spilled)
    }

    /// Cuts the empty bottom of a tall box: the rows after the last one that differs from the box's background.
    private static func trimmed(_ rep: NSBitmapImageRep, canvasHeight: CGFloat) -> NSBitmapImageRep {
        guard let data = rep.bitmapData, let cg = rep.cgImage else { return rep }
        let pixelsPerPoint = CGFloat(rep.pixelsHigh) / canvasHeight
        let m = Int(margin * pixelsPerPoint)
        let width = rep.pixelsWide, height = rep.pixelsHigh, bytes = rep.bytesPerRow, spp = rep.samplesPerPixel
        let reference = data + (m + 2) * bytes + (m + 2) * spp
        var last = m
        for y in stride(from: height - m - 1, through: m, by: -1) {
            var differs = false
            for x in stride(from: m + 1, to: width - m - 1, by: 2) {
                let p = data + y * bytes + x * spp
                if abs(Int(p[0]) - Int(reference[0])) > 2 || abs(Int(p[1]) - Int(reference[1])) > 2
                    || abs(Int(p[2]) - Int(reference[2])) > 2
                {
                    differs = true
                    break
                }
            }
            if differs { last = y; break }
        }
        let bottom = min(height, last + Int(30 * pixelsPerPoint))
        guard let cut = cg.cropping(to: CGRect(x: 0, y: 0, width: width, height: bottom)) else { return rep }
        return NSBitmapImageRep(cgImage: cut)
    }

    /// Counts pixels in the flagged margin that are not the flag colour (the view drew there).
    private static func countSpilledPixels(_ rep: NSBitmapImageRep, margin: Int) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let width = rep.pixelsWide, height = rep.pixelsHigh, bytes = rep.bytesPerRow, spp = rep.samplesPerPixel
        // The flag after colour management is not exactly (255, 0, 255): the corner pixel says what it became.
        let flag = (data[0], data[1], data[2])
        func isFlag(_ p: UnsafeMutablePointer<UInt8>) -> Bool {
            // Next to a shadow or a blend the flag is drawn without colour management: nearly pure magenta.
            (abs(Int(p[0]) - Int(flag.0)) <= 3 && abs(Int(p[1]) - Int(flag.1)) <= 3 && abs(Int(p[2]) - Int(flag.2)) <= 3)
                || (p[0] > 225 && p[1] < 70 && p[2] > 225)
        }
        var count = 0
        for y in 0..<height {
            let inBand = y < margin || y >= height - margin
            for x in 0..<width where inBand || x < margin || x >= width - margin {
                let p = data + y * bytes + x * spp
                // Anti-aliased edges of the box itself reach one pixel into the margin: ignore the last 2 pixels.
                let nearBox = x >= margin - 2 && x < width - margin + 2 && y >= margin - 2 && y < height - margin + 2
                if nearBox { continue }
                if !isFlag(p) { count += 1 }
            }
        }
        return count
    }
}
