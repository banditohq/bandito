import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// Crew, the home tab: the agents that wait for the person on top, then the team. The server switcher sits in the title
/// area under the large title (a menu when there is more than one server).
struct CrewScreen: View {
    let servers: [ServerModel]
    let settings: IOSSettings
    let onConnect: () -> Void
    /// Switches to the Inbox tab (the "Ещё N" line of the waiting agents).
    let onShowInbox: () -> Void
    /// An agent a `bandito://agent/...` link asked for: the screen opens its row, as a tap on the row does.
    var focus: CrewFocus?

    /// The server shown; nil means the first one (the list of servers can change under the screen).
    @State private var chosenServerID: UUID?
    /// The chats and the agent cards opened from the list (a waiting card pushes its chat by hand, so it has no chevron).
    @State private var path = NavigationPath()
    /// The creation sheet, while it is open: the tab it opens on. A new value is a new sheet.
    @State private var newAgent: NewAgentStart?
    /// The request of the focus that is already open: a link opens once, even when its agent is listed later.
    @State private var openedRequest: UUID?
    #if DEBUG
    @State private var hooksOpened = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let server = currentServer {
                    CrewList(
                        server: server, servers: servers, riskyNeedsFaceID: settings.riskyNeedsFaceID,
                        // The path is reset here, not on a change of the chosen server: a widget's link sets both.
                        onChoose: { chosenServerID = $0; path = NavigationPath() },
                        open: { path.append($0) },
                        details: { path.append(AgentDetailRoute(agentID: $0)) },
                        onCreate: { newAgent = NewAgentStart(tab: .teams) },
                        showInbox: onShowInbox
                    )
                    .id(server.id)
                } else {
                    WelcomeView(onConnect: onConnect)
                }
            }
            .newTaskButton()
            .navigationTitle(L10n.Ios.Tab.crew)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if currentServer != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            newAgent = NewAgentStart(tab: .teams)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L10n.Ios.Crew.createAgent)
                        .accessibilityIdentifier("crew.new")
                    }
                }
            }
            .navigationDestination(for: CrewRoute.self) { route in
                if let server = currentServer {
                    ChatScreen(server: server, agentID: route.agentID, settings: settings)
                }
            }
            .navigationDestination(for: AgentDetailRoute.self) { route in
                if let server = currentServer {
                    AgentDetailView(server: server, agentID: route.agentID)
                }
            }
        }
        .task(id: focus) {
            open(focus)
        }
        // On a cold start a widget or Spotlight link comes before the agents are listed: it waits for them.
        .onChange(of: servers.map { $0.agents.map(\.id) }) { _, _ in
            open(focus)
        }
        #if DEBUG
        .onChange(of: servers.count, initial: true) { _, _ in openScreenshotHooks() }
        #endif
        .sheet(item: $newAgent) { start in
            if let server = currentServer {
                NewAgentSheet(server: server, tab: start.tab)
            }
        }
    }

    #if DEBUG
    /// The screenshot hooks, read once from the launch arguments as `-tab` is: `-agent-card <name>` opens that agent's
    /// card, `-new-agent` opens the creation sheet (`-new-agent one` on its one-agent tab). Debug builds only.
    private func openScreenshotHooks() {
        guard !hooksOpened, let server = currentServer else { return }
        hooksOpened = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-agent-card"), arguments.indices.contains(index + 1),
           let agent = server.sortedAgents.first(where: { $0.name == arguments[index + 1] })
        {
            path.append(AgentDetailRoute(agentID: agent.id))
        }
        if let name = ChatLaunchHooks.value(after: "-chat", in: arguments),
           let agent = server.sortedAgents.first(where: { $0.name == name })
        {
            path.append(CrewRoute(agentID: agent.id, name: agent.name))
        }
        if let index = arguments.firstIndex(of: "-new-agent") {
            let one = arguments.indices.contains(index + 1) && arguments[index + 1] == "one"
            newAgent = NewAgentStart(tab: one ? .one : .teams)
        }
    }
    #endif

    private var currentServer: ServerModel? {
        servers.first { $0.id == chosenServerID } ?? servers.first
    }

    /// Opens the agent a link named: its server is shown, and its row is opened, once per request. An agent that is not
    /// listed yet waits (a cold start); one that never comes is ignored.
    private func open(_ focus: CrewFocus?) {
        guard let focus, focus.request != openedRequest, focus.isListed(in: servers),
              let server = servers.first(where: { $0.id == focus.serverID }),
              let agent = server.agents.first(where: { $0.id == focus.agentID })
        else { return }
        openedRequest = focus.request
        chosenServerID = server.id
        path = NavigationPath([CrewRoute(agentID: agent.id, name: agent.name)])
    }
}

/// A chat opened from the Crew list: the agent and its name, for the chat's title.
struct CrewRoute: Hashable {
    let agentID: String
    let name: String
}

/// An agent a widget or a link asked the Crew to open. `request` is new for every request, so the same agent asked
/// twice opens twice.
struct CrewFocus: Equatable {
    let serverID: UUID
    let agentID: String
    let request: UUID

    /// Whether the focus's agent is listed on its server now. A link that arrives before the servers are connected is not.
    @MainActor func isListed(in servers: [ServerModel]) -> Bool {
        servers.contains { server in
            server.id == serverID && server.agents.contains { $0.id == agentID }
        }
    }
}

/// The agent card opened from the Crew list ("Details" in the context menu).
struct AgentDetailRoute: Hashable {
    let agentID: String
}

/// The list of one server's crew. Reads the server's agents and their thread summaries; each row is an `Equatable`
/// view of its facts (`CrewAgentRow`), so the list rebuilds the rows that changed and no others.
struct CrewList: View {
    let server: ServerModel
    let servers: [ServerModel]
    /// The setting: a risky approval asks for Face ID before it is allowed (the rule is `InboxAnswer`'s, as in the Inbox).
    let riskyNeedsFaceID: Bool
    /// The owner's check for risky approvals (Face ID, else the passcode).
    var authenticator: any BiometricAuthenticating = DeviceAuthenticator()
    let onChoose: (UUID) -> Void
    /// Opens an agent's chat (the screen's navigation path).
    let open: (CrewRoute) -> Void
    /// Opens an agent's card.
    let details: (String) -> Void
    /// Opens the sheet that makes an agent (the empty state's button).
    let onCreate: () -> Void
    /// Switches to the Inbox tab, where every waiting item is.
    let showInbox: () -> Void

    @State private var pinned: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The toast after an answer ("Allowed — Forge goes on"), set by RootView.
    @Environment(\.answerToast) private var answerToast
    /// The Inbox items answered from this list, hidden at once while the server takes the answer.
    @State private var answered: Set<String> = []
    /// The item whose answer is on its way: its card shows a spinner and every answer is off until it ends.
    @State private var answering: String?
    /// Why an answer did not go through, by item: shown under its card.
    @State private var problems: [String: String] = [:]

    var body: some View {
        let rows = CrewFacts.build(server: server, pinned: pinned, answered: answered)
        let waiting = rows.filter { $0.waiting != nil }
        let approvals = CrewFacts.waitingItems(of: server, answered: answered)
        let notice = CrewFacts.notice(
            state: server.state, agentsReadAt: server.agentsReadAt, fromCache: server.agentsFromCache)
        List {
            serverSwitch
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: BanditoSpace.s5, bottom: 0, trailing: BanditoSpace.s5))
                .listRowSeparator(.hidden)

            if !rows.isEmpty, notice == .offline || notice == .offlineWithCache {
                offlineLine
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: BanditoSpace.s5, bottom: 0, trailing: BanditoSpace.s5))
                    .listRowSeparator(.hidden)
            }

            if !waiting.isEmpty {
                let split = CrewWaitingSplit.split(waiting)
                Section {
                    ForEach(split.shown) { facts in
                        let item = CrewFacts.approvalItem(approvals[facts.id])
                        // The card's top is a button that opens the chat; its answers are beside it, not inside it.
                        NeedsYouCard(
                            facts: facts, approval: item,
                            answering: item != nil && answering == item?.id,
                            disabled: answering != nil,
                            problem: item.flatMap { problems[$0.id] },
                            onOpen: { open(CrewRoute(agentID: facts.id, name: facts.name)) },
                            onAllow: { if let item { Task { await answer(item, allow: true) } } },
                            onDeny: { if let item { Task { await answer(item, allow: false) } } }
                        )
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(cardInsets)
                    }
                    if split.more > 0 {
                        Button {
                            showInbox()
                        } label: {
                            HStack(spacing: BanditoSpace.s2) {
                                Text(L10n.Ios.Crew.moreInInbox(count: split.more))
                                    .font(BanditoFont.text(size: 14, weight: 500))
                                    .foregroundStyle(Color.Bandito.signal)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.Bandito.signal)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(cardInsets)
                    }
                } header: {
                    CrewSectionLabel(title: L10n.Ios.Crew.needsYou, waiting: true)
                }
            }

            if rows.isEmpty {
                Section {
                    emptyState(notice)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(rows) { facts in
                        NavigationLink(value: CrewRoute(agentID: facts.id, name: facts.name)) {
                            CrewAgentRow(facts: facts).equatable()
                        }
                        .listRowBackground(Color.Bandito.surface1)
                        .contextMenu {
                            Button {
                                details(facts.id)
                            } label: {
                                Label(L10n.Inspector.details, systemImage: "info.circle")
                            }
                            Button {
                                pinned = CrewPins.toggled(facts.id, in: pinned)
                                CrewPins.save(pinned, serverID: server.id)
                            } label: {
                                Label(
                                    facts.isPinned ? L10n.Agent.Menu.unpin : L10n.Agent.Menu.pin,
                                    systemImage: facts.isPinned ? "pin.slash" : "pin")
                            }
                            Button {
                                let paused = !facts.isPaused
                                Task { _ = try? await server.setPaused(agentID: facts.id, paused) }
                            } label: {
                                Label(
                                    facts.isPaused ? L10n.Agent.Menu.resume : L10n.Agent.Menu.pause,
                                    systemImage: facts.isPaused ? "play" : "pause")
                            }
                        }
                    }
                } header: {
                    CrewSectionLabel(title: L10n.Sidebar.team)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .refreshable {
            // Pull to refresh means "check now": the agents are read again from the server.
            try? await server.readAgentsNow()
        }
        .task(id: server.id) {
            pinned = CrewPins.load(server.id)
        }
    }

    /// Sends the person's answer to an approval, as the Inbox does (`InboxAnswer`: a risky one waits for Face ID, and a
    /// cancelled check sends nothing). One answer at a time: a second tap meanwhile does nothing. A sent answer hides the
    /// item with the brand's ease (none with Reduce Motion) and gives a haptic, success to allow and warning to refuse.
    private func answer(_ item: InboxItem, allow: Bool) async {
        guard answering == nil else { return }
        answering = item.id
        problems[item.id] = nil
        defer { answering = nil }
        do {
            let outcome: InboxAnswer.Outcome
            if allow {
                outcome = try await InboxAnswer.allow(
                    item, server: server, remember: false, riskyNeedsFaceID: riskyNeedsFaceID,
                    authenticator: authenticator, reason: L10n.Ios.Inbox.faceIDReason)
            } else {
                try await InboxAnswer.deny(item, server: server)
                outcome = .sent
            }
            switch outcome {
            case .sent:
                UINotificationFeedbackGenerator().notificationOccurred(allow ? .success : .warning)
                let text = allow
                    ? L10n.Ios.AnswerToast.allowed(name: item.agentName)
                    : L10n.Ios.AnswerToast.denied(name: item.agentName)
                answerToast?.show(AnswerToastMessage(text: text, allowed: allow))
                withAnimation(reduceMotion ? nil : BanditoMotion.ease) {
                    _ = answered.insert(item.id)
                }
            case .notConfirmed:
                // The person cancelled the check: nothing was sent, and nothing is said.
                break
            case .cannotConfirm:
                problems[item.id] = L10n.Ios.Settings.Security.unavailable
            case .failed:
                problems[item.id] = L10n.Ios.Inbox.failed
            }
        } catch {
            problems[item.id] = L10n.Ios.Inbox.failed
        }
    }

    /// The insets of a waiting card or its line: one step of `s1` above and below, so two cards are `s2` apart.
    private var cardInsets: EdgeInsets {
        EdgeInsets(top: BanditoSpace.s1, leading: BanditoSpace.s4, bottom: BanditoSpace.s1, trailing: BanditoSpace.s4)
    }

    /// The server's name under the large title: a menu to choose another server when there are several.
    @ViewBuilder private var serverSwitch: some View {
        let label = HStack(spacing: BanditoSpace.s2) {
            Circle()
                .fill(server.state == .connected ? Color.Bandito.ok : Color.Bandito.text3)
                .frame(width: 7, height: 7)
            Text(server.config.name)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
            if servers.count > 1 {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .padding(.top, BanditoSpace.s1)
        if servers.count > 1 {
            Menu {
                ForEach(servers) { candidate in
                    Button(candidate.config.name) { onChoose(candidate.id) }
                }
            } label: {
                label
            }
            .accessibilityLabel(L10n.Ios.Crew.serverSwitch)
            .accessibilityValue(server.config.name)
        } else {
            label
                .accessibilityElement(children: .combine)
        }
    }

    /// One quiet line over a list that is not live (the saved copy of an earlier list, or one that the connection lost).
    private var offlineLine: some View {
        HStack(spacing: BanditoSpace.s2) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
                .accessibilityHidden(true)
            Text(L10n.Ios.Connection.cachedLine)
                .font(BanditoFont.text(size: 13))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: BanditoSpace.s2)
            Button {
                retry()
            } label: {
                Text(L10n.Ios.Connection.retry)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.signal)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.retry")
        }
        .padding(.vertical, BanditoSpace.s1)
    }

    private func retry() {
        Task { await server.connect() }
    }

    /// No agent shown. Connected: a sleeping raccoon, one line, and the action that opens the creation sheet. Not
    /// connected the list says nothing about the server's team, so it says so (`ConnectionNoticeView`).
    @ViewBuilder private func emptyState(_ notice: CrewConnectionNotice) -> some View {
        switch notice {
        case .connecting:
            ConnectionNoticeView(kind: .connecting, serverName: server.config.name, retry: retry)
        case .offline, .offlineWithCache:
            ConnectionNoticeView(kind: .offline, serverName: server.config.name, retry: retry)
        case .none:
            createState
        }
    }

    /// No agent on this server: a sleeping raccoon, one line, and the action that opens the creation sheet.
    private var createState: some View {
        VStack(spacing: BanditoSpace.s3) {
            CrewAvatar(
                name: "", look: CrewLook(color: .peach, face: .sleeping, customHex: nil), mood: .sleeping, size: 72)
            Text(L10n.Ios.Crew.emptyTitle)
                .font(BanditoFont.display(size: 16.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Ios.Crew.emptyMessage)
                .font(BanditoFont.text(size: 13.5))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Button {
                onCreate()
            } label: {
                Text(L10n.Ios.Crew.createAgent)
            }
            .accessibilityIdentifier("crew.empty.create")
            .buttonStyle(SignalButtonStyle())
            .padding(.top, BanditoSpace.s2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BanditoSpace.s6)
    }
}

/// The creation sheet's start: the tab it opens on. Identifiable, so every opening is a sheet of its own.
struct NewAgentStart: Identifiable {
    let id = UUID()
    let tab: NewAgentSheet.Tab
}
