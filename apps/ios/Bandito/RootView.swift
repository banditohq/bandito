import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreSpotlight
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings (docs/IOS_APP.md).
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The servers: the paired ones (saved list and Keychain tokens), or the `-demo` world.
    @State private var session = ServerSession.shared
    /// The connect sheet, with the way the person chose before it opened (the sheet is built from this value, not from
    /// state read later: a sheet built from `isPresented` saw the old choice).
    @State private var connect: ConnectRequest?
    /// A `bandito://pair` link opened from outside, until the connect sheet takes it.
    @State private var incomingLink: String?
    /// The explanation before the system's notification question, shown after the first server is connected.
    @State private var asksNotifications = false
    #if DEBUG
    /// `-tab <name>` opens a tab at launch (the screenshots); release builds always open Crew.
    @State private var tab = AppTab.requested(in: ProcessInfo.processInfo.arguments)
    #else
    @State private var tab = AppTab.crew
    #endif
    @State private var settings = IOSSettings()
    /// The account of this iPhone: its servers follow it from the Mac (docs/RELAY.md, "One account on every device").
    #if DEBUG
    /// `-account-preview <stage>` shows the account screen with made-up data (the screenshots).
    @State private var account = IOSAccount.previewFromLaunch() ?? IOSAccount.shared
    @State private var showsAccount = IOSAccount.previewFromLaunch() != nil
    #else
    @State private var account = IOSAccount.shared
    /// The account screen over the onboarding ("I have a Bandito account").
    @State private var showsAccount = false
    #endif
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
                CrewScreen(servers: servers, settings: settings, onConnect: openConnect, focus: crewFocus)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
                    .tag(AppTab.crew)
                InboxScreen(servers: servers, settings: settings, focus: $inboxFocus, openChat: openChat)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
                    .badge(InboxRules.badge(of: servers))
                    .tag(AppTab.inbox)
                ActivityScreen(servers: servers, settings: settings)
                    .id(dynamicTypeSize)
                    .badge(ActivityFacts.unreadCount(servers: servers))
                    .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
                    .tag(AppTab.activity)
                SettingsTab(
                    settings: settings, session: session, account: account, biometrics: biometrics,
                    onConnect: openConnect)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .preferredColorScheme(settings.theme.colorScheme)

            if showsOnboarding {
                OnboardingView(store: onboarding, motion: settings.motion, onConnect: { mode in
                    connect = ConnectRequest(mode: mode)
                }, onHaveAccount: { showsAccount = true })
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
            account.setActive(phase == .active)
            if phase == .active { TurnActivities.shared.appBecameActive() }
        }
        // An account that is ready ends the onboarding: the servers of the account come to this iPhone without pairing.
        .onChange(of: account.stage == .ready) { _, isReady in
            guard isReady else { return }
            onboarding.markCompleted()
            showsAccount = false
        }
        .onChange(of: notifications.route) { _, route in
            open(route)
        }
        .onOpenURL { url in
            if url.scheme?.lowercased() == "bandito", url.host?.lowercased() == "pair" {
                // A pairing link: the connect sheet shows it and asks before anything is sent.
                incomingLink = url.absoluteString
                connect = ConnectRequest(mode: .scanCode)
            } else if let link = BanditoLink(url: url) {
                openLink(link)
            }
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
        .onChange(of: session.current.map(\.id)) { _, ids in
            SpotlightAgentIndex.shared.keepOnly(serverIDs: Set(ids.map(\.uuidString)))
            TurnActivities.shared.serversChanged(ids: Set(ids))
        }
        .onChange(of: settings.liveActivities) { _, enabled in
            TurnActivities.shared.settingChanged(enabled: enabled)
        }
        .onChange(of: session.current.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { onboarding.markCompleted() }
        }
        // The notifications and the widgets follow the servers as they come and go.
        .onChange(of: session.current.map(\.id), initial: true) { _, _ in
            notifications.attach(session.current)
            ChatOutbox.shared.attach(session.current)
        }
        // Accents are the brand's signal orange (a link, a menu's chevron); the tab bar itself stays cream on warm dark.
        .tint(Color.Bandito.signal)
        .task {
            appLock.start(enabled: settings.faceIDLock)
            let arguments = ProcessInfo.processInfo.arguments
            notifications.settings = settings
            notifications.source = SessionNotificationSource(session: session)
            TurnActivities.shared.configure(
                servers: { ServerSession.shared.current }, isEnabled: { [settings] in settings.liveActivities })
            AppIntentHub.shared.liveServers = { ServerSession.shared.current }
            WidgetSnapshotWriter.shared.onPicture = { SpotlightAgentIndex.shared.sync($0.directory) }
            WidgetSnapshotWriter.shared.watch { ServerSession.shared.current }
            if !IOSDemo.isRequested(in: arguments) {
                // A stored account session is read and its cycle starts; with none this does nothing.
                Task {
                    await account.start()
                    account.setActive(scenePhase == .active)
                }
            }
            if IOSDemo.isRequested(in: arguments) {
                guard session.current.isEmpty else { return }
                session.installDemo(await IOSDemo.startServers(withTeam: !IOSDemo.isEmptyRequested(in: arguments)))
                #if DEBUG
                if arguments.contains(TurnActivities.demoArgument) {
                    TurnActivities.shared.runDemo(servers: session.current, arguments: arguments)
                }
                #endif
                return
            }
            session.loadIfNeeded()
            if PairingLaunchHooks.opensConnect() {
                incomingLink = PairingLaunchHooks.link()
                connect = ConnectRequest(mode: .scanCode)
            }
        }
        .sheet(item: $connect, onDismiss: { Task { await askNotificationsIfFirstServer() } }) { request in
            ConnectServerView(
                session: session, incomingLink: $incomingLink, start: request.mode, onClose: { connect = nil })
        }
        .sheet(isPresented: $showsAccount) {
            NavigationStack { AccountScreen(account: account, onClose: { showsAccount = false }) }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $asksNotifications) {
            NotificationAskSheet(onDone: { asksNotifications = false })
                .presentationDetents([.medium])
        }
    }

    /// Opens an agent's chat in the Crew (the Inbox sheet's button).
    private func openChat(serverID: UUID, agentID: String) {
        tab = .crew
        crewFocus = CrewFocus(serverID: serverID, agentID: agentID, request: UUID())
    }

    /// Opens the connect sheet on the camera (the Crew's and Settings' "Connect a server").
    private func openConnect() {
        connect = ConnectRequest(mode: .scanCode)
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
        case .agent(let agentID):
            tab = .crew
            if let server = session.current.first(where: { $0.agents.contains { $0.id == agentID } }) {
                crewFocus = CrewFocus(serverID: server.id, agentID: agentID, request: UUID())
            }
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

/// A request to open the connect sheet, and the way to connect it starts on.
struct ConnectRequest: Identifiable {
    let id = UUID()
    let mode: OnboardingConnectMode
}
