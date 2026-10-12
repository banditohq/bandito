import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings (docs/IOS_APP.md).
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The demo servers of the `-demo` launch arguments; empty without them.
    @State private var demoServers: [ServerModel] = []
    @State private var showsConnect = false
    @State private var tab = AppTab.requested(in: ProcessInfo.processInfo.arguments)
    @State private var settings = IOSSettings()
    @State private var servers = ConnectedServers.launch(demo: IOSDemo.isRequested(in: ProcessInfo.processInfo.arguments))
    @State private var appLock = AppLock()
    private let biometrics = DeviceAuthenticator()

    var body: some View {
        TabView(selection: $tab) {
            CrewScreen(servers: demoServers, onConnect: { showsConnect = true })
                .id(dynamicTypeSize)
                .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
                .tag(AppTab.crew)
            InboxScreen(servers: demoServers, settings: settings)
                .id(dynamicTypeSize)
                .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
                .badge(InboxRules.badge(of: demoServers))
                .tag(AppTab.inbox)
            ActivityScreen(servers: demoServers)
                .id(dynamicTypeSize)
                .badge(ActivityFacts.unreadCount(servers: demoServers))
                .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
                .tag(AppTab.activity)
            SettingsTab(settings: settings, servers: servers, biometrics: biometrics, onConnect: { showsConnect = true })
                .id(dynamicTypeSize)
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .overlay {
            if appLock.isLocked {
                LockScreen(onUnlock: unlockApp)
                    .id(dynamicTypeSize)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            appLock.scenePhaseChanged(to: phase, enabled: settings.faceIDLock, timeout: settings.lockTimeout)
        }
        // Accents are the brand's signal orange (a link, a menu's chevron); the tab bar itself stays cream on warm dark.
        .tint(Color.Bandito.signal)
        .task {
            appLock.start(enabled: settings.faceIDLock)
            let arguments = ProcessInfo.processInfo.arguments
            guard demoServers.isEmpty, IOSDemo.isRequested(in: arguments) else { return }
            demoServers = await IOSDemo.startServers(withTeam: !IOSDemo.isEmptyRequested(in: arguments))
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
