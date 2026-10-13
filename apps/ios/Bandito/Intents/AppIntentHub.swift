import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the App Intents and Spotlight need from the app: its live servers when it runs, else the snapshot the app wrote
/// for the widgets; a request to open a screen (a link), which RootView opens; and the send of a message to an agent.
@MainActor
@Observable
final class AppIntentHub {
    static let shared = AppIntentHub(store: WidgetSnapshotStore.appGroup())

    /// The live servers, set by RootView. Empty when the app has none (no pairing yet, or not running).
    @ObservationIgnored var liveServers: @MainActor () -> [ServerModel] = { [] }
    /// The screen an intent asked the app to open. RootView opens it and calls `consumeLink`.
    private(set) var pendingLink: BanditoLink?
    @ObservationIgnored private let store: WidgetSnapshotStore?

    init(store: WidgetSnapshotStore?) {
        self.store = store
    }

    /// The agents an intent can name: the live servers' agents when the app has any, else the last snapshot's directory.
    func directory() -> [WidgetSnapshot.Listing] {
        let live = liveServers()
        if !live.isEmpty { return WidgetSnapshotBuilder.directory(servers: live) }
        return store?.read()?.directory ?? []
    }

    func agents() -> [AgentEntity] {
        AgentDirectory.entities(directory())
    }

    /// The picture of what waits for the person: the live one when the app runs, else the snapshot (nil before the first).
    func needsMeSnapshot() -> WidgetSnapshot? {
        let live = liveServers()
        if !live.isEmpty { return WidgetSnapshotBuilder.make(servers: live) }
        return store?.read()
    }

    func open(_ link: BanditoLink) {
        pendingLink = link
    }

    func consumeLink() {
        pendingLink = nil
    }

    /// Sends the text to the agent through its server, then asks RootView to show the agent. Returns the dialog's line.
    func ask(_ agent: AgentEntity, text: String) async throws -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw AgentAskError.empty }
        guard let server = liveServers().first(where: { $0.id.uuidString == agent.serverID }) else {
            throw AgentAskError.notConnected(name: agent.name)
        }
        // Woken by Siri without the screens, the server may not be connected yet: connect it now.
        if server.state != .connected { await server.connect() }
        guard server.state == .connected else { throw AgentAskError.notConnected(name: agent.name) }
        do {
            try await server.send(message, to: agent.agentID)
        } catch {
            throw AgentAskError.failed(name: agent.name)
        }
        pendingLink = .agent(server: agent.serverID, id: agent.agentID)
        return L10n.Ios.Intent.Ask.sent(name: agent.name)
    }
}

/// Why a message did not go, as the Shortcuts and Siri dialog says it.
enum AgentAskError: Error, CustomLocalizedStringResourceConvertible {
    case empty
    case notConnected(name: String)
    case failed(name: String)

    var message: String {
        switch self {
        case .empty: L10n.Ios.Intent.Ask.empty
        case .notConnected(let name): L10n.Ios.Intent.Ask.notConnected(name: name)
        case .failed(let name): L10n.Ios.Intent.Ask.failed(name: name)
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}
