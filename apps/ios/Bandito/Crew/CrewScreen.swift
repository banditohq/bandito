import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Crew, the home tab: the agents that wait for the person on top, then the team. The server switcher sits in the title
/// area under the large title (a menu when there is more than one server).
struct CrewScreen: View {
    let servers: [ServerModel]
    let onConnect: () -> Void
    /// An agent a `bandito://agent/...` link asked for: the screen opens its row, as a tap on the row does.
    var focus: CrewFocus?

    /// The server shown; nil means the first one (the list of servers can change under the screen).
    @State private var chosenServerID: UUID?
    /// The chats and the agent cards opened from the list (a waiting card pushes its chat by hand, so it has no chevron).
    @State private var path = NavigationPath()
    /// The creation sheet, while it is open: the tab it opens on. A new value is a new sheet.
    @State private var newAgent: NewAgentStart?
    @State private var hooksOpened = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let server = currentServer {
                    CrewList(
                        server: server, servers: servers,
                        // The path is reset here, not on a change of the chosen server: a widget's link sets both.
                        onChoose: { chosenServerID = $0; path = NavigationPath() },
                        open: { path.append($0) },
                        details: { path.append(AgentDetailRoute(agentID: $0)) },
                        onCreate: { newAgent = NewAgentStart(tab: .teams) }
                    )
                    .id(server.id)
                } else {
                    WelcomeView(onConnect: onConnect)
                }
            }
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
                AgentChatStub(name: route.name)
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
        .onChange(of: servers.count, initial: true) { _, _ in openScreenshotHooks() }
        .sheet(item: $newAgent) { start in
            if let server = currentServer {
                NewAgentSheet(server: server, tab: start.tab)
            }
        }
    }

    /// The screenshot hooks, read once from the launch arguments as `-tab` is: `-agent-card <name>` opens that agent's
    /// card, `-new-agent` opens the creation sheet (`-new-agent one` on its one-agent tab).
    private func openScreenshotHooks() {
        guard !hooksOpened, let server = currentServer else { return }
        hooksOpened = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-agent-card"), arguments.indices.contains(index + 1),
           let agent = server.sortedAgents.first(where: { $0.name == arguments[index + 1] })
        {
            path.append(AgentDetailRoute(agentID: agent.id))
        }
        if let index = arguments.firstIndex(of: "-new-agent") {
            let one = arguments.indices.contains(index + 1) && arguments[index + 1] == "one"
            newAgent = NewAgentStart(tab: one ? .one : .teams)
        }
    }

    private var currentServer: ServerModel? {
        servers.first { $0.id == chosenServerID } ?? servers.first
    }

    /// Opens the agent a link named: its server is shown, and its row is opened. An agent that is not there is ignored.
    private func open(_ focus: CrewFocus?) {
        guard let focus, let server = servers.first(where: { $0.id == focus.serverID }),
              let agent = server.agents.first(where: { $0.id == focus.agentID })
        else { return }
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
    let onChoose: (UUID) -> Void
    /// Opens an agent's chat (the screen's navigation path).
    let open: (CrewRoute) -> Void
    /// Opens an agent's card.
    let details: (String) -> Void
    /// Opens the sheet that makes an agent (the empty state's button).
    let onCreate: () -> Void

    @State private var pinned: [String] = []

    var body: some View {
        let rows = CrewFacts.build(server: server, pinned: pinned)
        let waiting = rows.filter { $0.waiting != nil }
        List {
            serverSwitch
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: BanditoSpace.s5, bottom: 0, trailing: BanditoSpace.s5))
                .listRowSeparator(.hidden)

            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { facts in
                        // A button, not a link: the card is full width, with no disclosure chevron of the list.
                        Button {
                            open(CrewRoute(agentID: facts.id, name: facts.name))
                        } label: {
                            NeedsYouCard(facts: facts)
                                .padding(.vertical, BanditoSpace.s1)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    CrewSectionLabel(title: L10n.Ios.Crew.needsYou, waiting: true)
                }
            }

            if rows.isEmpty {
                Section {
                    emptyState
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

    /// No agent on this server: a sleeping raccoon, one line, and the action that opens the creation sheet.
    private var emptyState: some View {
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

/// The chat of an agent is not built yet: this screen holds its place, with the agent's name.
struct AgentChatStub: View {
    let name: String

    var body: some View {
        VStack(spacing: BanditoSpace.s3) {
            Text(L10n.Ios.Crew.chatSoon(name: name))
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The creation sheet's start: the tab it opens on. Identifiable, so every opening is a sheet of its own.
struct NewAgentStart: Identifiable {
    let id = UUID()
    let tab: NewAgentSheet.Tab
}
