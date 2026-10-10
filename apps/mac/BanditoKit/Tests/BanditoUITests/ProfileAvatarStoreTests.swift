import BanditoKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import BanditoUI

/// The profile picture on this Mac and its merge with the sync blob. Files go to a temporary folder, the change time and
/// the owner's removal flag to a private defaults suite.
@MainActor
@Suite struct ProfileAvatarStoreTests {
    private let directory: URL
    private let defaults: UserDefaults
    private let user = "user-1"

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: "profile-avatar-tests-\(UUID().uuidString)") ?? .standard
    }

    private var file: URL { directory.appendingPathComponent(ProfileAvatarStore.fileName(userID: user)) }

    private func store() async -> ProfileAvatarStore {
        let store = ProfileAvatarStore(directory: directory, defaults: defaults)
        await store.bind(userID: user)
        return store
    }

    /// A small valid JPEG, as the profile step writes it.
    private func jpeg() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = try #require(context.makeImage())
        return try #require(AvatarPicture.jpeg(image: image, crop: AvatarCrop(), side: 256))
    }

    /// Random pixels at full size as a JPEG: noise compresses badly, so it is over the 64 KB limit.
    private func noisyJPEG(side: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<(side * side * 4)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(
            CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func settingAPictureStoresItAndSyncsIt() async throws {
        let picture = try jpeg()
        let avatar = await store()
        try await avatar.setPicture(picture, at: 1_000)
        #expect(avatar.image != nil)
        #expect(await avatar.currentSyncedProfile() == SyncedProfile(avatar: picture, updatedAt: 1_000))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func settingAPictureRejectsBytesThatAreNotAPicture() async throws {
        let avatar = await store()
        await #expect(throws: ProfileAvatarStore.StoreError.invalidPicture) {
            try await avatar.setPicture(Data([1, 2, 3]), at: 1_000)
        }
        #expect(avatar.image == nil)
        #expect(avatar.updatedAt == 0)
    }

    @Test func removingAPictureSyncsAnExplicitClearedCopy() async throws {
        let avatar = await store()
        try await avatar.setPicture(try jpeg(), at: 1_000)
        try await avatar.removePicture(at: 2_000)
        #expect(avatar.image == nil)
        #expect(await avatar.currentSyncedProfile() == SyncedProfile(avatar: nil, cleared: true, updatedAt: 2_000))
    }

    @Test func aNeverSetPictureHasNothingToSync() async {
        #expect(await store().currentSyncedProfile() == nil)
    }

    @Test func pictureRemovalAndTimeSurviveARestart() async throws {
        let picture = try jpeg()
        try await store().setPicture(picture, at: 3_000)
        let reopened = await store()
        #expect(reopened.image != nil)
        #expect(reopened.updatedAt == 3_000)
        try await reopened.removePicture(at: 4_000)
        let afterRemoval = await store()
        #expect(afterRemoval.image == nil)
        #expect(await afterRemoval.currentSyncedProfile() == SyncedProfile(avatar: nil, cleared: true, updatedAt: 4_000))
    }

    @Test func missingProfileInTheBlobRemovesNothing() async throws {
        let avatar = await store()
        try await avatar.setPicture(try jpeg(), at: 1_000)
        let changed = try await avatar.apply(nil)
        #expect(changed == false)
        #expect(avatar.image != nil)
        #expect(avatar.updatedAt == 1_000)
    }

    @Test func newerPictureFromTheBlobIsWritten() async throws {
        let picture = try jpeg()
        let avatar = await store()
        #expect(try await avatar.apply(SyncedProfile(avatar: picture, updatedAt: 5_000)))
        #expect(avatar.image != nil)
        #expect(avatar.updatedAt == 5_000)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func corruptPictureFromTheBlobIsNotClearedAndNotStored() async throws {
        // A broken picture in the blob must not turn into a removal, nor replace a good local picture.
        let avatar = await store()
        let good = try jpeg()
        try await avatar.setPicture(good, at: 1_000)
        #expect(try await avatar.apply(SyncedProfile(avatar: Data([9, 9, 9]), updatedAt: 5_000)) == false)
        #expect(avatar.image != nil)
        #expect(avatar.removed == false)
        #expect(avatar.updatedAt == 1_000)
        #expect(await avatar.currentSyncedProfile() == SyncedProfile(avatar: good, updatedAt: 1_000))
    }

    @Test func corruptPictureOnEmptyDiskIsNotClearedEither() async throws {
        let avatar = await store()
        #expect(try await avatar.apply(SyncedProfile(avatar: Data([9, 9, 9]), updatedAt: 5_000)) == false)
        #expect(avatar.updatedAt == 0)
        #expect(avatar.removed == false)
        #expect(await avatar.currentSyncedProfile() == nil)
    }

    @Test func pictureOverTheSixtyFourKilobyteLimitIsRefused() async throws {
        let big = try noisyJPEG(side: 800)
        #expect(big.count > 64 * 1024)
        let avatar = await store()
        #expect(try await avatar.apply(SyncedProfile(avatar: big, updatedAt: 5_000)) == false)
        await #expect(throws: ProfileAvatarStore.StoreError.invalidPicture) {
            try await avatar.setPicture(big, at: 6_000)
        }
        #expect(avatar.image == nil)
    }

    @Test func damagedFileOnDiskReadsAsNoPictureNotAsRemoval() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: file)
        defaults.set(1_000, forKey: ProfileAvatarStore.updatedKeyPrefix + user)
        let avatar = await store()
        #expect(avatar.image == nil)
        #expect(avatar.removed == false)
        #expect(await avatar.currentSyncedProfile() == nil)
    }

    @Test func olderBlobCopyChangesNothing() async throws {
        let avatar = await store()
        try await avatar.setPicture(try jpeg(), at: 9_000)
        #expect(try await avatar.apply(SyncedProfile(avatar: nil, cleared: true, updatedAt: 4_000)) == false)
        #expect(avatar.image != nil)
    }

    @Test func newerClearedCopyFromTheBlobRemovesThePicture() async throws {
        let avatar = await store()
        try await avatar.setPicture(try jpeg(), at: 1_000)
        #expect(try await avatar.apply(SyncedProfile(avatar: nil, cleared: true, updatedAt: 6_000)))
        #expect(avatar.image == nil)
        #expect(await avatar.currentSyncedProfile() == SyncedProfile(avatar: nil, cleared: true, updatedAt: 6_000))
    }

    @Test func copyThatIsNeitherPictureNorClearedIsIgnored() async throws {
        let avatar = await store()
        #expect(try await avatar.apply(SyncedProfile(avatar: nil, updatedAt: 7_000)) == false)
        #expect(avatar.updatedAt == 0)
    }

    @Test func clearingForgetsThePictureOfThisUser() async throws {
        let avatar = await store()
        try await avatar.setPicture(try jpeg(), at: 1_000)
        try avatar.clear()
        #expect(avatar.image == nil)
        #expect(avatar.updatedAt == 0)
        #expect(await avatar.currentSyncedProfile() == nil)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test func bindingTheSameUserAgainDoesNotReadTheFileAgain() async throws {
        // The account object is set many times per run; a late second read must not undo a fresh save.
        let avatar = await store()
        try await avatar.setPicture(try jpeg(), at: 1_000)
        try FileManager.default.removeItem(at: file)
        await avatar.bind(userID: user)
        #expect(avatar.image != nil)
        #expect(avatar.updatedAt == 1_000)
    }

    @Test func aSavedPictureShowsAfterARestartWithoutTheServer() async throws {
        try await store().setPicture(try jpeg(), at: 1_000)
        // A new store, as after a restart: bound from the remembered user id alone.
        let restarted = ProfileAvatarStore(directory: directory, defaults: defaults)
        await restarted.bind(userID: user)
        #expect(restarted.image != nil)
        #expect(restarted.updatedAt == 1_000)
    }

    @Test func clearDuringApplyLeavesNoFileBehind() async throws {
        let picture = try jpeg()
        let avatar = await store()
        let applying = Task { try await avatar.apply(SyncedProfile(avatar: picture, updatedAt: 5_000)) }
        await Task.yield()
        try avatar.clear()
        let changed = try await applying.value
        #expect(changed == false)
        #expect(avatar.image == nil)
        #expect(avatar.updatedAt == 0)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test func clearDuringSetPictureLeavesNoFileBehind() async throws {
        let picture = try jpeg()
        let avatar = await store()
        let saving = Task { try await avatar.setPicture(picture, at: 5_000) }
        await Task.yield()
        try avatar.clear()
        try await saving.value
        #expect(avatar.image == nil)
        #expect(avatar.updatedAt == 0)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test func pictureIsPerUser() async throws {
        let first = await store()
        try await first.setPicture(try jpeg(), at: 1_000)
        let other = ProfileAvatarStore(directory: directory, defaults: defaults)
        await other.bind(userID: "user-2")
        #expect(other.image == nil)
        #expect(other.updatedAt == 0)
    }

    @Test func fileNameIsSafeForAnyUserID() {
        #expect(ProfileAvatarStore.fileName(userID: "abc-123_X") == "profile-avatar-abc-123_X.jpg")
        #expect(ProfileAvatarStore.fileName(userID: "../evil/id") == "profile-avatar-___evil_id.jpg")
    }
}

@MainActor
@Suite struct ProfileMergeWithServersTests {
    private let older = SyncedProfile(avatar: Data([1]), updatedAt: 1_000)
    private let newer = SyncedProfile(avatar: Data([2]), updatedAt: 2_000)

    @Test func serverPublishKeepsTheNewerLocalPicture() {
        let merged = ServerSyncPayload.merge(
            local: SyncPayload(profile: newer), remote: SyncPayload(profile: older))
        #expect(merged.profile == newer)
    }

    @Test func serverPublishKeepsTheRemotePictureWhenLocalHasNone() {
        let merged = ServerSyncPayload.merge(local: SyncPayload(), remote: SyncPayload(profile: older))
        #expect(merged.profile == older)
    }
}
