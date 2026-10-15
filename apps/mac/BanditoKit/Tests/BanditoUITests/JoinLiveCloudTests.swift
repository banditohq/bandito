@testable import BanditoKit
import CryptoKit
import Foundation
import Testing

@testable import BanditoUI

/// The Mac's side of "Войти с помощью Mac" against a real cloud on this machine (`wrangler dev --local`, never a
/// deployed one). Skipped unless `BANDITO_LIVE_CLOUD_URL` is set to a loopback `…/api/v1` address.
///
/// 1. `BANDITO_LIVE_SEED_SQL=<file>` writes the SQL that seeds the local database: a user, this test Mac as its approved
///    device, its session and a sync blob (all from fixed test keys, nothing of anybody's).
/// 2. With the cloud address set, the test runs as `JoinQRModel` would with that session: it makes a ticket, writes the
///    link to `BANDITO_LIVE_LINK_FILE`, waits for a phone to scan it (up to three minutes), checks the proof and approves.
@MainActor
@Suite(.serialized) struct JoinLiveCloudTests {
    private static let agreementKey = Data(repeating: 0x11, count: 32)
    private static let signingKey = Data(repeating: 0x22, count: 32)
    private static let syncKey = Data(repeating: 0x33, count: 32)
    private static let token = "live-token-0123456789abcdef0123456789abcdef"
    private static let userID = "live-user"
    private static let deviceID = "live-mac"
    private static let macName = "Studio Mac 🦝"

    nonisolated private static var cloudURL: String? {
        let value = ProcessInfo.processInfo.environment["BANDITO_LIVE_CLOUD_URL"]
        return value?.isEmpty == false ? value : nil
    }

    nonisolated private static var seedPath: String? {
        let value = ProcessInfo.processInfo.environment["BANDITO_LIVE_SEED_SQL"]
        return value?.isEmpty == false ? value : nil
    }

    private static func identity() throws -> (DeviceIdentity, MemorySecretStore) {
        let store = MemorySecretStore()
        try store.save(agreementKey, account: "x25519")
        try store.save(signingKey, account: "ed25519")
        return (try DeviceIdentity.make(from: store), store)
    }

    @Test(.enabled(if: JoinLiveCloudTests.seedPath != nil)) func writesTheSeedOfTheLocalDatabase() throws {
        let (identity, _) = try Self.identity()
        let payload = try JSONEncoder().encode(SyncPayload(servers: []))
        let blob = try SyncKey.sealBlob(
            payload, key: SymmetricKey(data: Self.syncKey),
            associatedData: SyncKey.blobAssociatedData(accountID: Self.userID, version: 1))
        let tokenHash = SHA256.hash(data: Data(Self.token.utf8)).map { String(format: "%02x", $0) }.joined()
        let sql = """
            INSERT INTO users (id, email) VALUES ('\(Self.userID)', 'live@example.com');
            INSERT INTO devices (id, user_id, name, platform, public_key, signing_key, approved)
              VALUES ('\(Self.deviceID)', '\(Self.userID)', '\(Self.macName)', 'macos', '\(identity.publicKeyBase64)', '\(identity.signingKeyBase64)', 1);
            INSERT INTO sessions (token_hash, user_id, device_id, expires_at)
              VALUES ('\(tokenHash)', '\(Self.userID)', '\(Self.deviceID)', '2099-01-01T00:00:00.000Z');
            INSERT INTO sync (user_id, version, blob) VALUES ('\(Self.userID)', 1, '\(blob)');

            """
        let target = try #require(Self.seedPath)
        try sql.write(toFile: target, atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: JoinLiveCloudTests.cloudURL != nil)) func aPhoneThatScansTheCodeIsLetIn() async throws {
        let (identity, store) = try Self.identity()
        let session = Session(
            token: Self.token, user: AccountUser(id: Self.userID, email: "live@example.com", name: nil, githubLogin: nil),
            device: DeviceRef(id: Self.deviceID, approved: true))
        try store.save(try JSONEncoder().encode(session), account: AccountClient.sessionAccount)
        let cloud = try #require(Self.cloudURL)
        let base = try #require(URL(string: cloud))
        let client = try AccountClient(identity: identity, sessions: store, baseURL: base)
        let rawKey = try #require(Data(base64Encoded: identity.publicKeyBase64))
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey)

        let approvedCalls = LiveCounter()
        let model = JoinQRModel(
            backend: AccountJoinBackend(client: client, identity: identity), macPublicKey: publicKey, macName: Self.macName,
            blocker: { nil }, syncKey: { SymmetricKey(data: Self.syncKey) },
            onApproved: { approvedCalls.count += 1 }, pollInterval: .seconds(1))
        model.start()
        defer { model.close() }

        var link: String?
        for _ in 0..<100 where link == nil {
            if case .showing(let shown, _) = model.phase { link = shown }
            if case .failed(let message) = model.phase { Issue.record("no ticket: \(message.text)") ; return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let shown = try #require(link, "no ticket in ten seconds")
        let path = ProcessInfo.processInfo.environment["BANDITO_LIVE_LINK_FILE"] ?? NSTemporaryDirectory() + "join-link.txt"
        try shown.write(toFile: path, atomically: true, encoding: .utf8)
        print("JOIN_LINK_READY \(path)")

        // A phone scans it (by hand, within three minutes): the proof is checked and the phone is approved.
        var added: String?
        for _ in 0..<1800 where added == nil {
            switch model.phase {
            case .added(let name): added = name
            case .badProof, .failed, .expired: Issue.record("the sign-in ended with \(model.phase)") ; return
            default: break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let name = try #require(added, "no phone signed in within three minutes")
        print("JOIN_ADDED \(name)")
        #expect(approvedCalls.count == 1)
    }
}

private final class LiveCounter: @unchecked Sendable {
    // @unchecked: only touched from the main actor.
    var count = 0
}
