import Foundation
import Testing

@testable import BanditoKit

/// The profile picture travels in the encrypted payload: it round-trips, it is optional on the wire, and the newer copy
/// wins a merge.
@MainActor
@Suite struct ProfileSyncTests {
    private let older = SyncedProfile(avatar: Data([1, 2, 3]), updatedAt: 1_000)
    private let newer = SyncedProfile(avatar: Data([9, 8, 7]), updatedAt: 2_000)

    @Test func profileRoundTripsAndPictureIsBase64OnTheWire() throws {
        let payload = SyncPayload(profile: newer)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)
        #expect(decoded.profile == newer)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(Data([9, 8, 7]).base64EncodedString()))
    }

    @Test func payloadWithoutProfileStillDecodes() throws {
        // Written by a build before the profile existed.
        let json = #"{"version":1,"servers":[],"snippets":null}"#
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8))
        #expect(decoded.profile == nil)
    }

    @Test func newerProfileWinsTheMergeInEitherDirection() {
        let local = SyncPayload(profile: older)
        let remote = SyncPayload(profile: newer)
        #expect(SyncStore.merge(local: local, remote: remote).profile == newer)
        #expect(SyncStore.merge(local: remote, remote: local).profile == newer)
    }

    @Test func tieKeepsTheLocalProfile() {
        let local = SyncedProfile(avatar: Data([1]), updatedAt: 5_000)
        let remote = SyncedProfile(avatar: Data([2]), updatedAt: 5_000)
        #expect(SyncStore.merge(local: SyncPayload(profile: local), remote: SyncPayload(profile: remote)).profile == local)
    }

    @Test func oneSideWithoutProfileTakesTheOther() {
        #expect(SyncStore.merge(local: SyncPayload(), remote: SyncPayload(profile: older)).profile == older)
        #expect(SyncStore.merge(local: SyncPayload(profile: older), remote: SyncPayload()).profile == older)
        #expect(SyncStore.merge(local: SyncPayload(), remote: SyncPayload()).profile == nil)
    }

    @Test func clearedCopyWithNewerTimeReachesTheOtherMac() {
        let cleared = SyncedProfile(avatar: nil, cleared: true, updatedAt: 3_000)
        let merged = SyncStore.merge(local: SyncPayload(profile: cleared), remote: SyncPayload(profile: older))
        #expect(merged.profile == cleared)
    }

    @Test func olderClearedCopyDoesNotBeatANewerPicture() {
        let cleared = SyncedProfile(avatar: nil, cleared: true, updatedAt: 500)
        let merged = SyncStore.merge(local: SyncPayload(profile: cleared), remote: SyncPayload(profile: newer))
        #expect(merged.profile == newer)
    }

    @Test func aBlobWithoutProfileDoesNotRemoveTheLocalPicture() {
        // A build that predates the profile writes a blob without it: the local picture stays.
        let merged = SyncStore.merge(local: SyncPayload(profile: older), remote: SyncPayload())
        #expect(merged.profile == older)
        #expect(merged.profile?.cleared == false)
    }

    @Test func clearedFlagSurvivesTheWire() throws {
        let cleared = SyncedProfile(avatar: nil, cleared: true, updatedAt: 9)
        let data = try JSONEncoder().encode(SyncPayload(profile: cleared))
        #expect(try JSONDecoder().decode(SyncPayload.self, from: data).profile == cleared)
    }

    @Test func profileWithoutClearedKeyDecodesAsNotCleared() throws {
        let json = #"{"version":1,"servers":[],"profile":{"avatar":"AAEC","updatedAt":4}}"#
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8))
        #expect(decoded.profile == SyncedProfile(avatar: Data([0, 1, 2]), updatedAt: 4))
    }
}
