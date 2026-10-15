import AVFoundation
import BanditoDesign
import BanditoKit
import Foundation
import Speech

// The rules of the new-task sheet: which agents it offers and in what order, whether a task can be sent, which agent
// was used last, and whether the microphone is offered. Pure values; the sheet only shows them.

/// One agent the new-task sheet offers: one chip of its picker.
struct NewTaskOption: Identifiable, Equatable {
    let serverID: UUID
    let serverName: String
    let agentID: String
    let agentName: String
    let look: CrewLook
    let mood: AvatarMood
    let paused: Bool

    var id: String { "\(serverID.uuidString)/\(agentID)" }
}

/// The agent a task was last sent to, stored in `UserDefaults` as JSON under `NewTaskRules.lastKey`.
struct NewTaskChoice: Codable, Equatable {
    let serverID: UUID
    let agentID: String
}

enum NewTaskRules {
    static let lastKey = "ios.newTask.last"

    /// The agents of every connected server: each server's agents in its `sortedAgents` order, the paused ones last.
    @MainActor
    static func options(servers: [ServerModel]) -> [NewTaskOption] {
        servers.flatMap { server in
            server.sortedAgents.map { agent in
                NewTaskOption(
                    serverID: server.id, serverName: server.config.name, agentID: agent.id, agentName: agent.name,
                    look: CrewLook(agent: agent),
                    mood: AvatarMood.crew(
                        status: server.status(of: agent.id),
                        turnRunning: server.threadSummary(for: agent.id).turnRunning, paused: agent.paused),
                    paused: agent.paused)
            }
        }
    }

    /// The picker's order: the paused agents move to the end (keeping their order), then the agent used last comes
    /// first, unless it is paused (it stays at the end). A last agent that is no longer listed changes nothing.
    static func order(_ options: [NewTaskOption], last: NewTaskChoice?) -> [NewTaskOption] {
        let active = options.filter { !$0.paused }
        let paused = options.filter { $0.paused }
        guard let last, let index = active.firstIndex(where: { $0.serverID == last.serverID && $0.agentID == last.agentID })
        else { return active + paused }
        var result = active
        let chosen = result.remove(at: index)
        result.insert(chosen, at: 0)
        return result + paused
    }

    /// The text as it is sent: without the spaces and line breaks around it.
    static func message(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A task can be sent when an agent is chosen and the text is not blank.
    static func canSend(text: String, agentChosen: Bool) -> Bool {
        agentChosen && !message(for: text).isEmpty
    }

    /// The microphone is offered unless the person refused speech or the microphone, or the recognizer does not exist
    /// for this language right now.
    static func microphoneShown(
        speech: SFSpeechRecognizerAuthorizationStatus, microphone: AVAudioApplication.recordPermission,
        recognizerAvailable: Bool
    ) -> Bool {
        let speechRefused = speech == .denied || speech == .restricted
        return !speechRefused && microphone != .denied && recognizerAvailable
    }

    static func lastChoice(defaults: UserDefaults = .standard) -> NewTaskChoice? {
        guard let data = defaults.data(forKey: lastKey) else { return nil }
        return try? JSONDecoder().decode(NewTaskChoice.self, from: data)
    }

    static func remember(_ choice: NewTaskChoice, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: lastKey)
    }
}
