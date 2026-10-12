import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings. Crew and Settings have content so far; Inbox and
/// Activity are placeholders until their screens are built (docs/IOS_APP.md).
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// The demo server of the `-demo` launch argument; nil without it.
    @State private var demoServer: ServerModel?
    @State private var showsConnect = false
    @State private var tab = AppTab.requested(in: ProcessInfo.processInfo.arguments)
    @State private var settings = IOSSettings()
    @State private var servers = ConnectedServers.launch(demo: IOSDemo.isRequested(in: ProcessInfo.processInfo.arguments))
    @State private var appLock = AppLock()
    private let biometrics = DeviceAuthenticator()

    var body: some View {
        TabView(selection: $tab) {
            CrewTab(server: demoServer, onConnect: { showsConnect = true })
                .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
                .tag(AppTab.crew)
            ComingSoonTab(title: L10n.Ios.Tab.inbox)
                .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
                .tag(AppTab.inbox)
            ComingSoonTab(title: L10n.Ios.Tab.activity)
                .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
                .tag(AppTab.activity)
            SettingsTab(settings: settings, servers: servers, biometrics: biometrics, onConnect: { showsConnect = true })
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .tint(Color.Bandito.signalFill)
        .overlay {
            if appLock.isLocked {
                LockScreen(onUnlock: unlockApp)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            appLock.scenePhaseChanged(to: phase, enabled: settings.faceIDLock, timeout: settings.lockTimeout)
        }
        .task {
            appLock.start(enabled: settings.faceIDLock)
            guard demoServer == nil, IOSDemo.isRequested(in: ProcessInfo.processInfo.arguments) else { return }
            demoServer = await IOSDemo.start()
        }
        .sheet(isPresented: $showsConnect) {
            ConnectPlaceholderSheet()
        }
    }

    /// Asks for Face ID (or the passcode) and opens the app when the owner passes. Without any way to check the owner
    /// the lock cannot be enforced, so it opens rather than keeping the owner out of their own data.
    private func unlockApp() async {
        if !biometrics.isAvailable {
            appLock.unlock()
        } else if await biometrics.authenticate(reason: L10n.Ios.Settings.Security.unlockReason) {
            appLock.unlock()
        }
    }
}

/// The tabs. `-tab <name>` at launch opens one of them (`crew`, `inbox`, `activity`, `settings`), for the screenshots.
enum AppTab: String, CaseIterable, Hashable {
    case crew
    case inbox
    case activity
    case settings

    static func requested(in arguments: [String]) -> AppTab {
        guard let index = arguments.firstIndex(of: "-tab"), arguments.indices.contains(index + 1),
              let tab = AppTab(rawValue: arguments[index + 1]) else { return .crew }
        return tab
    }
}

/// Crew: the team of the demo server, or the welcome screen while no server is connected.
struct CrewTab: View {
    let server: ServerModel?
    let onConnect: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let server {
                    TeamList(server: server)
                } else {
                    WelcomeView(onConnect: onConnect)
                }
            }
            .navigationTitle(L10n.Ios.Tab.crew)
        }
    }
}

struct ComingSoonTab: View {
    let title: String

    var body: some View {
        NavigationStack {
            VStack(spacing: BanditoSpace.s3) {
                Image("Raccoon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(L10n.Ios.Tab.comingSoon)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(title)
        }
    }
}
