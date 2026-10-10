import BanditoKit
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Keys and pruning of the picture cache. Pure, so the rules (one picture per agent and server, the newest revision,
/// what goes when an agent is gone) are tested without a server.
enum AvatarPictureCache {
    /// Cache key of one picture: the server, the agent and the picture revision, so a new picture never reads an old one.
    static func key(serverID: String, agentID: String, rev: Int64) -> String {
        "\(serverID)/\(agentID)#\(rev)"
    }

    /// The key of the agent's picture on `serverID`, or nil when the daemon says it has none.
    static func pictureKey(for agent: Agent, serverID: String) -> String? {
        guard let spec = agent.avatar, spec.image == true, let rev = spec.imageRev else { return nil }
        return key(serverID: serverID, agentID: agent.id, rev: rev)
    }

    /// Keys of `agentID`'s other revisions on `serverID`, to drop once `keep` is cached.
    static func stale(_ keys: [String], serverID: String, agentID: String, keep: String) -> [String] {
        let prefix = "\(serverID)/\(agentID)#"
        return keys.filter { $0.hasPrefix(prefix) && $0 != keep }
    }

    /// Whether `key` belongs to `serverID` and to an agent that is no longer there.
    static func isGone(_ key: String, serverID: String, agentIDs: Set<String>) -> Bool {
        let prefix = "\(serverID)/"
        guard key.hasPrefix(prefix) else { return false }
        let agentID = key.dropFirst(prefix.count).prefix { $0 != "#" }
        return !agentIDs.contains(String(agentID))
    }
}

/// Pictures of agent avatars: decoded once per revision, kept in a bounded memory (64 pictures, least recently used
/// first), and dropped when their agent is gone. A load that fails is not repeated for a minute. Decoding runs off the
/// main thread; the main thread only stores the result.
@MainActor
@Observable
final class AvatarPictures {
    static let shared = AvatarPictures()
    static let capacity = 64
    static let failureTTL: TimeInterval = 60

    /// Bumped when a picture arrives or leaves, so views that read `image(for:)` redraw.
    private(set) var version = 0
    @ObservationIgnored private var cache = BoundedCache<CGImage>(capacity: AvatarPictures.capacity, failureTTL: AvatarPictures.failureTTL)
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The decoded picture for `key`, marking it as used. Nil when it is not loaded (yet).
    func image(for key: String) -> CGImage? {
        cache.value(for: key)
    }

    /// Loads the agent's picture if it has one and it is neither cached, loading, nor recently failed.
    func load(agent: Agent, server: ServerModel) async {
        let serverID = server.id.uuidString
        guard let key = AvatarPictureCache.pictureKey(for: agent, serverID: serverID),
            cache.value(for: key) == nil, !cache.hasFailed(key, now: now()), !inFlight.contains(key)
        else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        guard let picture = try? await server.agentAvatarImage(agent.id),
            let image = await AvatarPictures.decodeOffMain(picture.data)
        else {
            cache.recordFailure(for: key, at: now())
            return
        }
        // A picture that changed on the server has a newer revision; the older one is no longer shown.
        let stale = Set(AvatarPictureCache.stale(cache.keys, serverID: serverID, agentID: agent.id, keep: key))
        cache.retain { !stale.contains($0) }
        cache.insert(image, for: key)
        version += 1
    }

    /// Drops the pictures of agents that `server` no longer has, and the failures remembered for them.
    func retain(on server: ServerModel) {
        let serverID = server.id.uuidString
        let agentIDs = Set(server.agents.map(\.id))
        let before = cache.count
        cache.retain { !AvatarPictureCache.isGone($0, serverID: serverID, agentIDs: agentIDs) }
        if cache.count != before { version += 1 }
    }

    /// The first image of PNG or JPEG bytes. Nil for anything else. Safe off the main thread.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `decode` on a background thread: for the main thread, which only takes the result.
    nonisolated static func decodeOffMain(_ data: Data) async -> CGImage? {
        await Task.detached(operation: { decode(data) }).value
    }
}
