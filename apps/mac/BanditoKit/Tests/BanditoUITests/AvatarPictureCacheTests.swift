import Foundation
import BanditoKit
import Testing

@testable import BanditoUI

@Suite struct AvatarPictureCacheTests {
    private func agent(id: String, image: Bool?, rev: Int64?) -> Agent {
        let spec = AvatarSpec(color: "sky", face: "wink", image: image, imageRev: rev)
        return Agent(
            id: id, name: "Forge", role: "", runtime: .claude, model: nil, cwd: "/tmp", approvalMode: .risky,
            systemPrompt: nil, runtimeSessionId: nil, createdAt: 0, updatedAt: 0, avatar: spec)
    }

    @Test func keyCombinesServerAgentAndRevision() {
        #expect(AvatarPictureCache.key(serverID: "s1", agentID: "a1", rev: 42) == "s1/a1#42")
    }

    @Test func noPictureKeyWithoutImageFlagOrRevision() {
        #expect(AvatarPictureCache.pictureKey(for: agent(id: "a1", image: nil, rev: 42), serverID: "s1") == nil)
        #expect(AvatarPictureCache.pictureKey(for: agent(id: "a1", image: false, rev: 42), serverID: "s1") == nil)
        #expect(AvatarPictureCache.pictureKey(for: agent(id: "a1", image: true, rev: nil), serverID: "s1") == nil)
    }

    @Test func pictureKeyFollowsTheRevision() {
        #expect(AvatarPictureCache.pictureKey(for: agent(id: "a1", image: true, rev: 7), serverID: "s1") == "s1/a1#7")
    }

    @Test func staleKeysAreTheSameAgentsOtherRevisionsOnTheSameServer() {
        let keys = ["s1/a1#1", "s1/a1#2", "s1/a2#2", "s2/a1#1", "s1/a1#3"]
        #expect(AvatarPictureCache.stale(keys, serverID: "s1", agentID: "a1", keep: "s1/a1#3") == ["s1/a1#1", "s1/a1#2"])
        #expect(AvatarPictureCache.stale(keys, serverID: "s1", agentID: "a3", keep: "s1/a3#1") == [])
    }

    @Test func keysOfAnAgentThatIsGoneAreFoundOnlyOnItsServer() {
        let keys = ["s1/a1#1", "s1/a2#4", "s2/a9#1"]
        let present: Set<String> = ["a1"]
        #expect(AvatarPictureCache.isGone("s1/a2#4", serverID: "s1", agentIDs: present))
        #expect(AvatarPictureCache.isGone("s1/a1#1", serverID: "s1", agentIDs: present) == false)
        // Another server's agent is not this server's business.
        #expect(AvatarPictureCache.isGone("s2/a9#1", serverID: "s1", agentIDs: present) == false)
        #expect(keys.filter { AvatarPictureCache.isGone($0, serverID: "s1", agentIDs: present) } == ["s1/a2#4"])
    }

    @Test func emojiFaceAndPictureChoiceIsTheSharedRule() {
        #expect(AvatarPresentation.choose(hasPicture: true, emoji: "🦝") == .picture)
        #expect(AvatarPresentation.choose(hasPicture: false, emoji: "🦝") == .emoji("🦝"))
    }
}

@Suite struct BoundedCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func evictsTheLeastRecentlyUsedBeyondCapacity() {
        var cache = BoundedCache<Int>(capacity: 2, failureTTL: 60)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.value(for: "a")          // "a" is now the newer one
        cache.insert(3, for: "c")          // "b" goes
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.count == 2)
    }

    @Test func capacityOfSixtyFourHoldsSixtyFour() {
        var cache = BoundedCache<Int>(capacity: 64, failureTTL: 60)
        for index in 0..<70 { cache.insert(index, for: "k\(index)") }
        #expect(cache.count == 64)
        #expect(cache.value(for: "k0") == nil)
        #expect(cache.value(for: "k69") == 69)
    }

    @Test func failureIsRememberedForSixtySecondsOnly() {
        var cache = BoundedCache<Int>(capacity: 4, failureTTL: 60)
        cache.recordFailure(for: "a", at: t0)
        #expect(cache.hasFailed("a", now: t0.addingTimeInterval(59)))
        #expect(cache.hasFailed("a", now: t0.addingTimeInterval(61)) == false)
    }

    @Test func insertingAPictureClearsItsFailure() {
        var cache = BoundedCache<Int>(capacity: 4, failureTTL: 60)
        cache.recordFailure(for: "a", at: t0)
        cache.insert(1, for: "a")
        #expect(cache.hasFailed("a", now: t0.addingTimeInterval(1)) == false)
    }

    @Test func retainDropsRejectedKeysAndTheirFailures() {
        var cache = BoundedCache<Int>(capacity: 4, failureTTL: 60)
        cache.insert(1, for: "keep")
        cache.insert(2, for: "drop")
        cache.recordFailure(for: "drop", at: t0)
        cache.retain { $0 == "keep" }
        #expect(cache.value(for: "drop") == nil)
        #expect(cache.hasFailed("drop", now: t0) == false)
        #expect(cache.value(for: "keep") == 1)
    }
}
