import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings (docs/IOS_APP.md).
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The servers: the paired ones (saved list and Keychain tokens), or the `-demo` world.
    @State private var session = ServerSession.shared
    @State private var showsConnect = false
    /// A `bandito://pair` link opened from outside, until the connect sheet takes it.
    @State private var incomingLink: String?
    /// How the person chose to connect on the onboarding's last step (opens the sheet on that way).
    @State private var connectMode = OnboardingConnectMode.scanCode
    /// The explanation before the system's notification question, shown after the first server is connected.
    @State private var asksNotifications = false
    @State private var tab = AppTab.requested(in: ProcessInfo.processInfo.arguments)
    @State private var settings = IOSSettings()
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
        let servers = session.current
        let showsOnboarding = onboarding.shows(hasServers: !servers.isEmpty)
        ZStack {
            TabView(selection: $tab) {
                CrewScreen(servers: servers, onConnect: openConnect, focus: crewFocus)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
                    .tag(AppTab.crew)
                InboxScreen(servers: servers, settings: settings, focus: $inboxFocus)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
                    .badge(InboxRules.badge(of: servers))
                    .tag(AppTab.inbox)
                ActivityScreen(servers: servers)
                    .id(dynamicTypeSize)
                    .badge(ActivityFacts.unreadCount(servers: servers))
                    .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
                    .tag(AppTab.activity)
                SettingsTab(settings: settings, session: session, biometrics: biometrics, onConnect: openConnect)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .preferredColorScheme(settings.theme.colorScheme)

            if showsOnboarding {
                OnboardingView(store: onboarding, motion: settings.motion, onConnect: { mode in
                    connectMode = mode
                    showsConnect = true
                })
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
            if url.scheme?.lowercased() == "bandito", url.host?.lowercased() == "pair" {
                // A pairing link: the connect sheet shows it and asks before anything is sent.
                incomingLink = url.absoluteString
                showsConnect = true
            } else if let link = BanditoLink(url: url) {
                openLink(link)
            }
        }
        .onChange(of: session.current.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { onboarding.markCompleted() }
        }
        // The notifications and the widgets follow the servers as they come and go.
        .onChange(of: session.current.map(\.id), initial: true) { _, _ in
            notifications.attach(session.current)
        }
        // Accents are the brand's signal orange (a link, a menu's chevron); the tab bar itself stays cream on warm dark.
        .tint(Color.Bandito.signal)
        .task {
            appLock.start(enabled: settings.faceIDLock)
            let arguments = ProcessInfo.processInfo.arguments
            notifications.settings = settings
            notifications.source = SessionNotificationSource(session: session)
            WidgetSnapshotWriter.shared.watch { ServerSession.shared.current }
            if IOSDemo.isRequested(in: arguments) {
                guard session.current.isEmpty else { return }
                session.installDemo(await IOSDemo.startServers(withTeam: !IOSDemo.isEmptyRequested(in: arguments)))
                return
            }
            session.loadIfNeeded()
            if PairingLaunchHooks.opensConnect() {
                incomingLink = PairingLaunchHooks.link()
                showsConnect = true
            }
        }
        .sheet(isPresented: $showsConnect, onDismiss: { Task { await askNotificationsIfFirstServer() } }) {
            ConnectServerView(
                session: session, incomingLink: $incomingLink, start: connectMode, onClose: { showsConnect = false })
        }
        .sheet(isPresented: $asksNotifications) {
            NotificationAskSheet(onDone: { asksNotifications = false })
                .presentationDetents([.medium])
        }
    }

    /// Opens the connect sheet on the camera (the Crew's and Settings' "Connect a server").
    private func openConnect() {
        connectMode = .scanCode
        showsConnect = true
    }

    /// The first time a server is connected, explains and then asks for notifications ("just in time", docs/IOS_APP.md).
    /// Once: a person who said no is not asked again (Settings has the switch).
    private func askNotificationsIfFirstServer() async {
        guard !session.servers.isEmpty, !NotificationAsk.wasAsked else { return }
        guard await SystemNotifications.permission() == .notDetermined else { return }
        NotificationAsk.markAsked()
        asksNotifications = true
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
