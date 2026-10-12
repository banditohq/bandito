import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreSpotlight
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings (docs/IOS_APP.md).
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The demo servers of the `-demo` launch arguments; empty without them.
    @State private var demoServers: [ServerModel] = []
    @State private var showsConnect = false
    #if DEBUG
    /// `-tab <name>` opens a tab at launch (the screenshots); release builds always open Crew.
    @State private var tab = AppTab.requested(in: ProcessInfo.processInfo.arguments)
    #else
    @State private var tab = AppTab.crew
    #endif
    @State private var settings = IOSSettings()
    @State private var servers = ConnectedServers.launch(demo: IOSDemo.isRequested(in: ProcessInfo.processInfo.arguments))
    @State private var appLock = AppLock()
    /// The approval item the Inbox opens (a notification's route), cleared by the Inbox once it is open.
    @State private var inboxFocus: String?
    /// The agent a widget or a `bandito://agent/...` link asked the Crew to open.
    @State private var crewFocus: CrewFocus?
    /// The first run's progress; the flow covers the app until a server is paired (docs/IOS_APP.md, Onboarding).
    @State private var onboarding = OnboardingStore.launch(arguments: ProcessInfo.processInfo.arguments)
    private let biometrics = DeviceAuthenticator()
    private let notifications = IOSNotifications.shared

    var body: some View {
        let showsOnboarding = onboarding.shows(hasServers: !servers.servers.isEmpty)
        ZStack {
            TabView(selection: $tab) {
                CrewScreen(servers: demoServers, onConnect: { showsConnect = true }, focus: crewFocus)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
                    .tag(AppTab.crew)
                InboxScreen(servers: demoServers, settings: settings, focus: $inboxFocus)
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

            if showsOnboarding {
                OnboardingView(store: onboarding, motion: settings.motion, onConnect: { _ in showsConnect = true })
                    .id(dynamicTypeSize)
                    .transition(.opacity)
            }
        }
        .animation(BanditoMotion.ease, value: showsOnboarding)
        .overlay {
            if appLock.isLocked {
                LockScreen(onUnlock: unlockApp)
                    .id(dynamicTypeSize)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            appLock.scenePhaseChanged(to: phase, enabled: settings.faceIDLock, timeout: settings.lockTimeout)
            notifications.appActiveChanged(phase == .active)
        }
        .onChange(of: notifications.route) { _, route in
            open(route)
        }
        .onOpenURL { url in
            guard let link = BanditoLink(url: url) else { return }
            openLink(link)
        }
        // A Siri or Shortcuts intent asks for a screen (AppIntentHub), and a Spotlight result opens its agent.
        .onChange(of: AppIntentHub.shared.pendingLink) { _, link in
            guard let link else { return }
            AppIntentHub.shared.consumeLink()
            openLink(link)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let link = SpotlightAgents.link(from: activity) else { return }
            openLink(link)
        }
        .onChange(of: servers.servers.map(\.id)) { _, ids in
            SpotlightAgentIndex.shared.keepOnly(serverIDs: Set(ids.map(\.uuidString)))
        }
        .onChange(of: servers.servers.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { onboarding.markCompleted() }
        }
        // Accents are the brand's signal orange (a link, a menu's chevron); the tab bar itself stays cream on warm dark.
        .tint(Color.Bandito.signal)
        .task {
            appLock.start(enabled: settings.faceIDLock)
            let arguments = ProcessInfo.processInfo.arguments
            notifications.settings = settings
            AppIntentHub.shared.liveServers = { demoServers }
            WidgetSnapshotWriter.shared.onPicture = { SpotlightAgentIndex.shared.sync($0.directory) }
            WidgetSnapshotWriter.shared.watch { demoServers }
            guard demoServers.isEmpty, IOSDemo.isRequested(in: arguments) else { return }
            demoServers = await IOSDemo.startServers(withTeam: !IOSDemo.isEmptyRequested(in: arguments))
            notifications.source = StaticNotificationSource(servers: demoServers)
            notifications.attach(demoServers)
        }
        .sheet(isPresented: $showsConnect) {
            ConnectPlaceholderSheet()
        }
    }

    /// Opens the place a notification's press leads to. A risky approval opens the Inbox on its sheet.
    private func open(_ route: IOSNotifications.Route?) {
        guard let route else { return }
        switch route {
        case .agent:
            tab = .crew
        case .approval(let approvalID, _):
            inboxFocus = IOSNotifications.inboxItemID(approvalID: approvalID)
            tab = .inbox
        }
        notifications.consumeRoute()
    }

    /// Opens the place a widget or a link names: a tab, or an agent in the Crew.
    private func openLink(_ link: BanditoLink) {
        switch link {
        case .inbox:
            tab = .inbox
        case .crew:
            tab = .crew
        case .agent(let server, let id):
            tab = .crew
            if let serverID = UUID(uuidString: server) {
                crewFocus = CrewFocus(serverID: serverID, agentID: id, request: UUID())
            }
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

    #if DEBUG
    static func requested(in arguments: [String]) -> AppTab {
        guard let index = arguments.firstIndex(of: "-tab"), arguments.indices.contains(index + 1),
              let tab = AppTab(rawValue: arguments[index + 1]) else { return .crew }
        return tab
    }
    #endif
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
