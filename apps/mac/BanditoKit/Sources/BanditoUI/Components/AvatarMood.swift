import BanditoDesign
import BanditoKit

// The mood of an avatar from an agent's state. The moods themselves (`AvatarMood`, `AvatarPose`) live in BanditoDesign,
// shared with the iPhone app; the mapping from `AgentStatus` stays with the apps that know agents.

extension AvatarMood {
    /// Mood for an agent with `status`. A streamed reply reads as thinking, a running turn of an idle agent too.
    /// Waiting for a person and errors always win.
    /// A paused agent sleeps whatever it was doing: the pause interrupted its turn.
    public static func make(
        status: AgentStatus, turnRunning: Bool = false, streaming: Bool = false, paused: Bool = false
    ) -> AvatarMood {
        if paused { return .sleeping }
        return switch status {
        case .needsYou: .needsYou
        case .error: .error
        case .offline: .sleeping
        case .working: streaming ? .thinking : .working
        case .idle: (turnRunning || streaming) ? .thinking : .idle
        }
    }
}
