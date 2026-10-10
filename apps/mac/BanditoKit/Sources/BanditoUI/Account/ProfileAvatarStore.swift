import BanditoKit
import CoreGraphics
import Foundation
import Observation

/// The profile picture of the signed-in account on this Mac, kept per user id like the nickname: a JPEG in
/// `Application Support/Bandito/profile-avatar-<id>.jpg`, the time it last changed and whether the owner removed it
/// (in defaults). The sync blob carries the same copy, and `apply` takes the newer of the two.
///
/// A picture is only ever stored or taken when it decodes and is at most 64 KB. A blob copy that does not pass is
/// ignored, and a damaged file on disk reads as no picture, never as a removal: only the owner's own removal (or the
/// blob's explicit `cleared` copy) counts as one. Decoding and file access run off the main thread.
@MainActor
@Observable
final class ProfileAvatarStore {
    enum StoreError: Error, Equatable {
        /// The bytes are not a picture, or are over the 64 KB limit.
        case invalidPicture
    }

    static let updatedKeyPrefix = "profile.avatar.updatedAt."
    static let removedKeyPrefix = "profile.avatar.removed."

    /// The picture as shown; nil without one.
    private(set) var image: CGImage?
    /// When the picture last changed, Unix milliseconds. 0 when it never has, for this user.
    private(set) var updatedAt: Int64 = 0
    /// The last change was a removal (by the owner here, or by the blob).
    private(set) var removed = false

    @ObservationIgnored private var userID: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameters:
    ///   - directory: where the files live. Tests pass a temporary one.
    ///   - defaults: where the change time lives. Tests pass a private suite.
    init(directory: URL = ProfileAvatarStore.defaultDirectory(), defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    /// `Application Support/Bandito`.
    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Bandito", isDirectory: true)
    }

    /// The file name for a user id: the id with anything but letters, digits, `-` and `_` replaced.
    static func fileName(userID: String) -> String {
        let safe = String(userID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return "profile-avatar-\(safe).jpg"
    }

    /// Loads the state of `userID` (nil: nobody is signed in and nothing is shown). Only the file read is off the main
    /// thread; the state is set here.
    func bind(userID: String?) async {
        self.userID = userID
        guard let userID else {
            image = nil
            updatedAt = 0
            removed = false
            return
        }
        updatedAt = Int64(defaults.integer(forKey: Self.updatedKeyPrefix + userID))
        removed = defaults.bool(forKey: Self.removedKeyPrefix + userID)
        let url = fileURL(for: userID)
        let loaded = await Task.detached { Self.readPicture(at: url) }.value
        // The user may have changed while the file was read; only the current user's picture is shown.
        guard self.userID == userID else { return }
        image = loaded?.image
    }

    /// The copy the sync blob carries. Nil when this user never changed the picture, or when the file is missing or
    /// damaged and the owner did not remove it. Cleared only after the owner's own removal.
    func currentSyncedProfile() async -> SyncedProfile? {
        guard let userID, updatedAt > 0 else { return nil }
        if removed { return SyncedProfile(avatar: nil, cleared: true, updatedAt: updatedAt) }
        let url = fileURL(for: userID)
        guard let loaded = await Task.detached(operation: { Self.readPicture(at: url) }).value else { return nil }
        return SyncedProfile(avatar: loaded.data, updatedAt: updatedAt)
    }

    /// Stores a JPEG as the picture, changed at `time`. Throws when the bytes are not a picture within 64 KB.
    func setPicture(_ jpeg: Data, at time: Int64) async throws {
        guard let userID else { throw StoreError.invalidPicture }
        guard let image = await Task.detached(operation: { Self.validate(jpeg) }).value else {
            throw StoreError.invalidPicture
        }
        try await write(jpeg, to: fileURL(for: userID))
        self.image = image
        removed = false
        record(time)
    }

    /// Removes the picture, changed at `time`. The owner's removal is kept, so an older copy from the blob does not
    /// bring it back.
    func removePicture(at time: Int64) async throws {
        guard let userID else { return }
        try await removeFile(fileURL(for: userID))
        image = nil
        removed = true
        defaults.set(true, forKey: Self.removedKeyPrefix + userID)
        record(time)
    }

    /// Takes `remote` when it is newer than this user's copy and passes the checks: a cleared copy removes the picture,
    /// a picture must decode and be within 64 KB. Anything else changes nothing. Returns whether something changed.
    @discardableResult
    func apply(_ remote: SyncedProfile?) async throws -> Bool {
        guard let userID, let remote, remote.updatedAt > updatedAt else { return false }
        let url = fileURL(for: userID)
        if remote.cleared {
            try await removeFile(url)
            image = nil
            removed = true
        } else if let avatar = remote.avatar {
            guard let decoded = await Task.detached(operation: { Self.validate(avatar) }).value else { return false }
            try await write(avatar, to: url)
            image = decoded
            removed = false
        } else {
            return false
        }
        defaults.set(removed, forKey: Self.removedKeyPrefix + userID)
        record(remote.updatedAt)
        return true
    }

    /// Sign-out and reset: the picture of this user leaves this Mac. Keeps the user bound, like `ProfileStore.clear`.
    func clear() throws {
        guard let userID else { return }
        let url = fileURL(for: userID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        defaults.removeObject(forKey: Self.updatedKeyPrefix + userID)
        defaults.removeObject(forKey: Self.removedKeyPrefix + userID)
        image = nil
        updatedAt = 0
        removed = false
    }

    // MARK: - Off the main thread

    /// The decoded picture of `data` when it is a picture within the limit. Nil otherwise. Safe off the main thread.
    nonisolated static func validate(_ data: Data) -> CGImage? {
        guard data.count <= AvatarPicture.profileMaxBytes else { return nil }
        return AvatarPictures.decode(data)
    }

    /// The valid picture stored at `url`, with its bytes. Nil when there is no file or it does not pass.
    nonisolated static func readPicture(at url: URL) -> (image: CGImage, data: Data)? {
        guard let data = try? Data(contentsOf: url), let image = validate(data) else { return nil }
        return (image, data)
    }

    // MARK: - Private

    private func fileURL(for userID: String) -> URL {
        directory.appendingPathComponent(Self.fileName(userID: userID))
    }

    private func write(_ data: Data, to url: URL) async throws {
        let directory = directory
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }

    private func removeFile(_ url: URL) async throws {
        try await Task.detached {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }.value
    }

    private func record(_ time: Int64) {
        guard let userID else { return }
        updatedAt = time
        defaults.set(Int(time), forKey: Self.updatedKeyPrefix + userID)
    }
}
