import AppKit
import BanditoDesign
@testable import BanditoKit
import SwiftUI
import Testing

@testable import BanditoL10n
@testable import BanditoUI

/// Pictures of the cloud screens for a person to look at: the Connect iPhone wizard in every state, the cloud block and
/// the Tailscale helper in the server's settings. Written to `RELAY_SNAPSHOTS` (skipped when it is not set), in the dark
/// theme in Russian and the light theme in English, drawn from a view with no window on screen.
extension ScreenWorkSuites {
    @MainActor
    @Suite(.serialized) struct RelaySnapshots {
        nonisolated static var directory: URL? {
            guard let path = ProcessInfo.processInfo.environment["RELAY_SNAPSHOTS"], !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        static let looks: [(language: String, dark: Bool)] = [("ru", true), ("en", false)]

        private func draw(_ name: String, width: CGFloat, dark: Bool, env: AuditEnvironment, _ view: AnyView) throws {
            let directory = try #require(Self.directory)
            let content = env.wrap(view).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(
                rootView: ZStack(alignment: .top) {
                    Color.Bandito.surface2
                    content
                }
                .frame(width: width))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 4000)
            host.layoutSubtreeIfNeeded()
            let height = ceil(host.fittingSize.height)
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "\(name).png"))
        }

        private func each(_ name: String, width: CGFloat, signedIn: Bool = true, _ make: @MainActor (AuditEnvironment) -> AnyView) throws {
            for look in Self.looks {
                try L10n.withLanguageForTests(look.language) {
                    let env = AuditEnvironment(signedIn: signedIn)
                    defer { env.cleanUp() }
                    try draw("\(name)-\(look.language)-\(look.dark ? "dark" : "light")", width: width, dark: look.dark, env: env, make(env))
                }
            }
        }

        @Test(.enabled(if: RelaySnapshots.directory != nil)) func wizard() throws {
            try each("wizard-pick", width: 420) { _ in AnyView(ConnectPhoneWizard(preview: .pickServer, previewServers: ["Studio Mac", "Build machine in Frankfurt"])) }
            try each("wizard-preparing", width: 420) { _ in AnyView(ConnectPhoneWizard(preview: .preparing(detail: .connecting))) }
            try each("wizard-scan", width: 420) { _ in
                AnyView(ConnectPhoneWizard(preview: .scan(LayoutAuditSnapshots.cloudPairPreview)))
            }
            try each("wizard-done", width: 420) { _ in
                AnyView(ConnectPhoneWizard(preview: .done(device: "Anna’s iPhone"), previewServerName: "Studio Mac"))
            }
            try each("wizard-problem", width: 420) { _ in AnyView(ConnectPhoneWizard(preview: .problem(.noServer))) }
        }

        @Test(.enabled(if: RelaySnapshots.directory != nil)) func joinSheet() throws {
            let link = LayoutAuditSnapshots.joinPreviewLink
            let phases: [(String, JoinQRModel.Phase)] = [
                ("join-qr", .showing(link: link, expiresAt: Date().addingTimeInterval(272))),
                ("join-added", .added(name: "Anna’s iPhone")),
                ("join-bad-proof", .badProof(removed: true)),
                ("join-blocked", .blocked(.notApproved)),
            ]
            for (name, phase) in phases {
                try each(name, width: 420) { _ in AnyView(JoinQRSheet(preview: .preview(phase))) }
            }
        }

        @Test(.enabled(if: RelaySnapshots.directory != nil)) func settings() throws {
            try each("settings-cloud-on", width: 560) { env in
                env.serverInfo(features: ["server_settings", "phone_access", "pairing", "relay"])
                return AnyView(
                    ServerSettingsPage(
                        server: env.server, onBack: {}, preview: LayoutAuditSnapshots.serverSettingsPreview, previewDevices: LayoutAuditSnapshots.phoneDevicesPreview,
                        previewCloud: .connected))
            }
            try each("settings-cloud-signin", width: 560) { env in
                env.serverInfo(features: ["server_settings", "phone_access", "pairing", "relay"])
                return AnyView(
                    ServerSettingsPage(
                        server: env.server, onBack: {}, preview: LayoutAuditSnapshots.serverSettingsPreview, previewDevices: [],
                        previewCloud: .signIn))
            }
            try each("settings-tailscale-help", width: 560) { env in
                env.serverInfo(features: ["server_settings", "phone_access", "pairing", "relay"])
                var snapshot = LayoutAuditSnapshots.serverSettingsPreview
                snapshot.phone = PhoneAccessStatus(
                    mode: .tailscale, listening: [], error: "No Tailscale address on this machine. Install Tailscale and sign in.")
                snapshot.settings.phoneAccess = .tailscale
                return AnyView(
                    ServerSettingsPage(server: env.server, onBack: {}, preview: snapshot, previewDevices: [], previewCloud: .off))
            }
        }
    }
}
