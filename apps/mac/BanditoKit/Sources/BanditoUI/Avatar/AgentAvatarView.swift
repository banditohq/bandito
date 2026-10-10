import BanditoKit
import CoreGraphics
import SwiftUI

/// An agent's avatar wherever it appears: its picture when it has one, else its emoji, else the raccoon face. The
/// picture loads lazily on first appearance and is cached per revision (`AvatarPictures`). The mood moves the raccoon
/// only; a picture or an emoji is drawn still.
struct AgentAvatarView: View {
    let agent: Agent
    /// The server the agent lives on; needed to load a picture. Without it, a picture is not shown.
    let server: ServerModel?
    var size: CGFloat = 40
    var mood: AvatarMood = .idle

    private var pictureKey: String? {
        server.flatMap { AvatarPictureCache.pictureKey(for: agent, serverID: $0.id.uuidString) }
    }
    private var picture: CGImage? {
        _ = AvatarPictures.shared.version
        return pictureKey.flatMap { AvatarPictures.shared.image(for: $0) }
    }

    var body: some View {
        AvatarArtView(
            name: agent.name, look: AvatarLook(spec: agent.avatar, name: agent.name), picture: picture,
            size: size, mood: mood)
            .task(id: pictureKey) {
                guard let server, server.supports("avatar_pictures") else { return }
                AvatarPictures.shared.retain(on: server)
                await AvatarPictures.shared.load(agent: agent, server: server)
            }
    }
}
