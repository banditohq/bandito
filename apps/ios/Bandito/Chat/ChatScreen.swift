import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The chat with an agent, pushed from the Crew, the Activity, a notification or a link. The header is the agent: its
/// avatar with its mood, its name and what it does now; a tap opens its card. The list and the message box are UIKit
/// (`ChatViewController`).
struct ChatScreen: View {
    let server: ServerModel
    let agentID: String
    let settings: IOSSettings
    /// The thread row to open the chat at (an Activity entry); nil opens at the newest message.
    var focusRowID: String?

    @State private var model: ChatModel
    @State private var showsDetails = false
    @State private var showsChanges = false

    init(server: ServerModel, agentID: String, settings: IOSSettings, focusRowID: String? = nil) {
        self.server = server
        self.agentID = agentID
        self.settings = settings
        self.focusRowID = focusRowID
        _model = State(initialValue: ChatModel(server: server, agentID: agentID))
    }

    var body: some View {
        ChatControllerView(model: model, settings: settings, focusRowID: focusRowID, onOpenChanges: { showsChanges = true })
            .ignoresSafeArea(.all, edges: .bottom)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.Bandito.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        showsDetails = true
                    } label: {
                        ChatHeader(server: server, agentID: agentID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.header")
                }
            }
            .navigationDestination(isPresented: $showsDetails) {
                AgentDetailView(server: server, agentID: agentID)
            }
            .navigationDestination(isPresented: $showsChanges) {
                ChatChangesScreen(server: server, agentID: agentID)
            }
    }
}

/// The agent in the bar: avatar, name, and a line about what it does. Reads the thread's summary, never the thread: a
/// streamed token does not rebuild it.
struct ChatHeader: View {
    let server: ServerModel
    let agentID: String

    var body: some View {
        let agent = server.agents.first { $0.id == agentID }
        let summary = server.threadSummary(for: agentID)
        let status = server.status(of: agentID)
        let mood = AvatarMood.crew(status: status, turnRunning: summary.turnRunning, paused: agent?.paused ?? false)
        HStack(spacing: BanditoSpace.s2) {
            if let agent {
                CrewAvatar(name: agent.name, look: CrewLook(agent: agent), mood: mood, size: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(agent?.name ?? "")
                    .font(BanditoFont.display(size: 14.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(Self.statusLine(connected: server.state == .connected, status: status, turnRunning: summary.turnRunning))
                    .font(BanditoFont.text(size: 11.5, weight: 450))
                    .foregroundStyle(status == .needsYou ? Color.Bandito.signal : Color.Bandito.text3)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.Inspector.details)
    }

    /// "Working…", "Waiting for you", the agent's other states, or "No connection".
    static func statusLine(connected: Bool, status: AgentStatus, turnRunning: Bool) -> String {
        if !connected { return L10n.Ios.Chat.Header.offline }
        if status == .needsYou { return L10n.Ios.Chat.Header.waiting }
        if status == .working || turnRunning { return L10n.Ios.Chat.Header.working }
        switch status {
        case .error: return L10n.Status.error
        case .offline: return L10n.Status.offline
        default: return L10n.Status.idle
        }
    }
}

/// Hosts the chat's view controller.
struct ChatControllerView: UIViewControllerRepresentable {
    let model: ChatModel
    let settings: IOSSettings
    let focusRowID: String?
    let onOpenChanges: () -> Void

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(model: model, settings: settings)
        controller.focusRowID = focusRowID
        controller.onOpenChanges = onOpenChanges
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.onOpenChanges = onOpenChanges
    }
}
