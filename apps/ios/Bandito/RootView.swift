import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreSpotlight
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings (docs/IOS_APP.md).
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The scheme the screen shows now (the setting, or the system's). The sheets that RootView opens take it
    /// explicitly: they do not follow the tabs' scheme by themselves (the New task sheet came up dark in light).
    @Environment(\.colorScheme) private var shownScheme
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
    /// "Sign in" was chosen in the connect sheet: the account sheet follows when that sheet has closed.
    @State private var signsInAfterConnect = false
    @State private var appLock = AppLock(lockedAtLaunch: IOSSettings().faceIDLock)
    /// The approval item the Inbox opens (a notification's route), cleared by the Inbox once it is open.
    @State private var inboxFocus: String?
    /// The agent a widget or a `bandito://agent/...` link asked the Crew to open.
    @State private var crewFocus: CrewFocus?
    /// The new-task sheet, while it is open: a new value is a new sheet (the long press asks for the dictation).
    @State private var newTask: NewTaskRequest?
    /// What the screen does once the new-task sheet has closed (see `runNewTaskFollowUp`).
    @State private var newTaskFollowUp: NewTaskFollowUp?
    /// The toast after an answer to an agent ("Allowed — Forge goes on"); every tab reads it from the environment.
    @State private var answerToast = AnswerToastCenter()
    /// A `bandito://share/<id>` link that waits for Face ID: the task is sent and its chat opens once the app is open.
    @State private var pendingShare: UUID?
    /// A `bandito://join` code that waits for Face ID: the sign-in starts once the app is open.
    @State private var pendingJoin: JoinTicket?
    /// The question before a sign-in by a code that came from outside (the camera app, a pasted link, the connect scanner).
    @State private var joinConfirm: JoinConfirmRequest?
    /// A code read while another sheet was open: the question follows once that sheet has closed.
    @State private var confirmAfterSheet: JoinTicket?
    /// Toasts about shared tasks that were dropped while Face ID covered the app: shown once it is open.
    @State private var pendingNotices: [ShareNotice] = []
    /// The first run's progress; the flow covers the app until a server is paired (docs/IOS_APP.md, Onboarding).
    @State private var onboarding = OnboardingStore.launch(arguments: ProcessInfo.processInfo.arguments)
    private let biometrics = DeviceAuthenticator()
    private let notifications = IOSNotifications.shared

    var body: some View {
        let servers = session.current
        let showsOnboarding = onboarding.shows(hasServers: !servers.isEmpty)
        ZStack {
            TabView(selection: $tab) {
                CrewScreen(
                    servers: servers, settings: settings, account: account, onConnect: openConnect, onShowInbox: { tab = .inbox },
                    focus: crewFocus)
                    .id(dynamicTypeSize)
                    .environment(\.newTaskAction, newTaskAction(for: servers))
                    .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
                .tag(AppTab.crew)
                InboxScreen(servers: servers, settings: settings, focus: $inboxFocus, openChat: openChat)
                    .id(dynamicTypeSize)
                    .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
                    .badge(InboxRules.badge(of: servers))
                    .tag(AppTab.inbox)
                ActivityScreen(servers: servers, settings: settings)
                    .id(dynamicTypeSize)
                    .environment(\.newTaskAction, newTaskAction(for: servers))
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
            .environment(\.answerToast, answerToast)

            if showsOnboarding {
                OnboardingView(store: onboarding, motion: settings.motion, onConnect: { mode in
                    connect = ConnectRequest(mode: mode)
                }, onHaveAccount: { showsAccount = true })
                    .id(dynamicTypeSize)
                    .transition(.opacity)
            }

            #if DEBUG
            if SharePreview.isRequested(in: ProcessInfo.processInfo.arguments) {
                ShareView(model: SharePreview.model(empty: ProcessInfo.processInfo.arguments.contains("-share-empty")))
            }
            #endif
        }
        // One place decides the scheme: the onboarding is always dark, the app follows the setting. A second
        // preference inside the onboarding stayed on the sheets opened after it (the New task sheet was dark in light).
        .preferredColorScheme(showsOnboarding ? .dark : settings.theme.colorScheme)
        .animation(BanditoMotion.ease, value: showsOnboarding)
        .overlay(alignment: .bottom) {
            AnswerToastHost(center: answerToast)
        }
        .overlay {
            if appLock.isLocked {
                LockScreen(onUnlock: unlockApp)
                    .id(dynamicTypeSize)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            appLock.scenePhaseChanged(to: phase, enabled: settings.faceIDLock, timeout: settings.lockTimeout)
            if phase == .active { importSharedTasks() }
            notifications.appActiveChanged(phase == .active)
            account.setActive(phase == .active)
            if phase == .background { session.saveAgentCaches() }
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
        // An action of the app icon, also one that started the app. It waits while the lock screen covers the app.
        .onChange(of: QuickActionHub.shared.pending, initial: true) { _, _ in
            runPendingQuickAction()
        }
        // The lock closes the new-task sheet (a sheet is shown above the lock screen otherwise), and an action that
        // waited for Face ID runs once the app is open.
        .onChange(of: appLock.isLocked) { _, locked in
            if locked {
                newTask = nil
            } else {
                runPendingQuickAction()
                answerToast.showInTurn(pendingNotices.map { AnswerToastMessage(text: $0.text, allowed: false) })
                pendingNotices = []
                if let ticket = pendingJoin { askJoin(ticket) }
                if let id = pendingShare { openShared(id) } else { importSharedTasks() }
            }
        }
        .onOpenURL { url in
            if url.scheme?.lowercased() == "bandito", url.host?.lowercased() == "pair" {
                // A pairing link: the connect sheet shows it and asks before anything is sent.
                incomingLink = url.absoluteString
                connect = ConnectRequest(mode: .scanCode)
            } else if url.scheme?.lowercased() == "bandito", url.host?.lowercased() == "join" {
                // A code from a Mac, read by the camera app: this iPhone signs in with it, or says the code is no good.
                if let ticket = JoinTicket.parse(url) {
                    askJoin(ticket)
                } else {
                    answerToast.show(AnswerToastMessage(text: L10n.Ios.Join.expired, allowed: false))
                }
            } else if let link = BanditoLink(url: url) {
                if case .share(let id) = link {
                    openShared(id)
                } else {
                    openLink(link)
                }
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
            ShareImporter.shared.attach(.live(session: session))
            ShareImporter.shared.onNotice = { notice in showShareNotice(notice) }
            importSharedTasks()
        }
        // A server that comes online lets the tasks with pictures go.
        .onChange(of: session.current.filter { $0.state == .connected }.map(\.id)) { _, _ in
            importSharedTasks()
        }
        // Accents are the brand's signal orange (a link, a menu's chevron); the tab bar itself stays cream on warm dark.
        .tint(Color.Bandito.signal)
        .task {
            appLock.start(enabled: settings.faceIDLock)
            ShareImporter.shared.cleanUp()
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
                // `-demo -new-task` opens the new-task sheet at launch (the screenshots), as the icon's action does.
                if arguments.contains("-new-task") {
                    QuickActionHub.shared.request(.newTask)
                }
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
        .sheet(item: $connect, onDismiss: {
            // "Sign in" in the connect sheet: the account sheet opens once this one is gone.
            if let ticket = confirmAfterSheet {
                confirmAfterSheet = nil
                askJoin(ticket)
                return
            }
            if signsInAfterConnect {
                signsInAfterConnect = false
                showsAccount = true
                return
            }
            Task { await askNotificationsIfFirstServer() }
        }) { request in
            ConnectServerView(
                session: session, incomingLink: $incomingLink, start: request.mode,
                onSignIn: account.signedIn ? nil : {
                    signsInAfterConnect = true
                    connect = nil
                },
                onJoin: { askJoin($0) },
                onClose: { connect = nil })
                .preferredColorScheme(settings.theme.colorScheme ?? shownScheme)
        }
        .sheet(isPresented: $showsAccount, onDismiss: {
            if let ticket = confirmAfterSheet {
                confirmAfterSheet = nil
                askJoin(ticket)
            }
        }) {
            NavigationStack { AccountScreen(account: account, onClose: { showsAccount = false }) }
                .preferredColorScheme(.dark)
        }
        .sheet(item: $joinConfirm) { request in
            JoinConfirmSheet(
                ticket: request.ticket, alreadySignedIn: request.alreadySignedIn,
                onConfirm: {
                    joinConfirm = nil
                    startJoin(request.ticket)
                },
                onCancel: { joinConfirm = nil })
                .presentationDetents([.medium])
                .preferredColorScheme(settings.theme.colorScheme ?? shownScheme)
        }
        .sheet(isPresented: $asksNotifications) {
            NotificationAskSheet(onDone: { asksNotifications = false })
                .presentationDetents([.medium])
        }
        .sheet(item: $newTask, onDismiss: runNewTaskFollowUp) { request in
            NewTaskSheet(
                servers: servers, startsDictating: request.dictate,
                onFinish: { newTaskFollowUp = $0 })
                .preferredColorScheme(settings.theme.colorScheme ?? shownScheme)
        }
    }

    /// The floating New task button at the bottom right, above the tab bar. It is an inset of the tab's screen, so the
    /// last row of its list scrolls above the button. Shown only when a server is connected.
    /// The floating button's action, only when some server has an agent to give a task to.
    private func newTaskAction(for servers: [ServerModel]) -> NewTaskAction? {
        guard servers.contains(where: { !$0.agents.isEmpty }) else { return nil }
        return NewTaskAction(open: { openNewTask(dictate: $0) })
    }

    /// Opens the new-task sheet, or the dictation on it. Nothing opens while the lock screen covers the app.
    private func openNewTask(dictate: Bool) {
        guard !appLock.isLocked else { return }
        newTask = NewTaskRequest(dictate: dictate)
    }

    /// Does the icon's action, when the app is open and the lock does not cover it. The action stays pending until then.
    private func runPendingQuickAction() {
        guard !appLock.isLocked, let action = QuickActionHub.shared.pending else { return }
        QuickActionHub.shared.consume()
        switch action {
        case .newTask: openNewTask(dictate: false)
        case .inbox: tab = .inbox
        }
    }

    /// Does what the new-task sheet asked for, once it has closed: the sheet and the connect sheet cannot be open together.
    private func runNewTaskFollowUp() {
        guard let followUp = newTaskFollowUp else { return }
        newTaskFollowUp = nil
        switch followUp {
        case .connect:
            openConnect()
        case .crew:
            tab = .crew
        case .chat(let serverID, let agentID):
            openLink(.agent(server: serverID.uuidString, id: agentID))
        }
    }

    /// Sends what the share extension left, unless the lock covers the app (it waits for Face ID).
    private func importSharedTasks() {
        guard !appLock.isLocked else { return }
        Task { await ShareImporter.shared.drain() }
    }

    /// The toast of a dropped shared task; behind the lock it waits for Face ID.
    private func showShareNotice(_ notice: ShareNotice) {
        if appLock.isLocked {
            pendingNotices.append(notice)
        } else {
            answerToast.show(AnswerToastMessage(text: notice.text, allowed: false))
        }
    }

    /// A `bandito://share/<id>` link: the task is queued and the agent's chat opens. Behind the lock it waits.
    private func openShared(_ id: UUID) {
        guard !appLock.isLocked else {
            pendingShare = id
            return
        }
        pendingShare = nil
        Task {
            // The task is sent (or dropped) first: a task whose agent is gone opens no chat.
            await ShareImporter.shared.drain()
            // The lock may have closed while the task was sent: the chat waits for Face ID.
            guard !appLock.isLocked else {
                pendingShare = id
                return
            }
            guard let target = ShareImporter.shared.target(of: id) else { return }
            // A link that started the app can arrive before the saved servers are read: the chat opens once its server is there.
            var waited = 0
            while !session.current.contains(where: { $0.id == target.server }), waited < 30 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            openLink(.agent(server: target.server.uuidString, id: target.agent))
        }
    }

    /// Opens an agent's chat in the Crew (the Inbox sheet's button).
    private func openChat(serverID: UUID, agentID: String) {
        tab = .crew
        crewFocus = CrewFocus(serverID: serverID, agentID: agentID, request: UUID())
    }

    /// "Sign in with a Mac": a code came from outside the sign-in screen (the camera app, a pasted link, the connect sheet's
    /// scanner). Nothing is sent until the person says yes: a code on a poster or in a message would sign this iPhone in to
    /// somebody else's account. A phone that is in an account already does not sign in again: it says so. Behind the lock
    /// the code waits for Face ID.
    private func askJoin(_ ticket: JoinTicket) {
        guard !appLock.isLocked else {
            pendingJoin = ticket
            return
        }
        pendingJoin = nil
        // Two sheets cannot be open at once: the question follows when the one that is open has closed.
        if connect != nil {
            confirmAfterSheet = ticket
            connect = nil
            return
        }
        if showsAccount {
            confirmAfterSheet = ticket
            showsAccount = false
            return
        }
        Task {
            // A link that started the app finds the stored session not read yet.
            if account.stage == .loading { await account.start() }
            joinConfirm = JoinConfirmRequest(ticket: ticket, alreadySignedIn: account.stage == .ready)
        }
    }

    /// "Sign in" in the question: the account screen shows the wait.
    private func startJoin(_ ticket: JoinTicket) {
        // The account may have become ready while the question was open.
        if account.stage == .ready {
            joinConfirm = JoinConfirmRequest(ticket: ticket, alreadySignedIn: true)
            return
        }
        showsAccount = true
        Task { await account.join(ticket) }
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
        case .link(let url):
            if let link = BanditoLink(url: url) { openLink(link) }
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
        case .share(let id):
            openShared(id)
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

/// The question before a sign-in by a code from outside (or the answer that this iPhone is in an account already).
struct JoinConfirmRequest: Identifiable {
    let id = UUID()
    let ticket: JoinTicket
    let alreadySignedIn: Bool
}
