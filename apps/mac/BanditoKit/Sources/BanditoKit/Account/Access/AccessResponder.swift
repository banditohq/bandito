import CryptoKit
import Foundation

/// The parts of the sync store the access code needs. `SyncStore` is one; tests pass a fake.
@MainActor
public protocol AccessSyncing: AnyObject {
    func pull() async throws -> SyncPayload?
    @discardableResult func update(_ mutate: (inout SyncPayload) -> Void) async throws -> SyncPayload
}

extension SyncStore: AccessSyncing {}

/// The parts of the account client the access code needs.
public protocol AccessAccount: Sendable {
    func me() async throws -> Me
    func restoreSession() async throws -> Session?
}

extension AccountClient: AccessAccount {}

/// The answering side of "servers follow you" (docs/RELAY.md, "One account on every device"). Each cycle it reads the
/// account's blob and, for every request to a server this device is connected to, asks the daemon for a device
/// (`devices.issue`), seals the token to the asking device (`DeviceTokenSeal`), writes the grant and removes the request.
///
/// One request is answered once: the issue is remembered in the `AccessLedger` before anything else is written, a grant
/// that could not be written is kept there and written by the next cycle, and a request that comes back after it was
/// answered is removed, not answered again.
@MainActor
public final class AccessResponder {
    public struct Outcome: Equatable, Sendable {
        /// Tokens issued in this cycle.
        public var issued = 0
        /// Requests that could not be answered now (the daemon refused, or sealing failed).
        public var failed = 0
        /// Requests for servers this device is not connected to.
        public var waiting = 0
        /// Device rows revoked in this cycle.
        public var revoked = 0
    }

    private let sync: AccessSyncing
    private let account: AccessAccount
    private let identity: DeviceIdentity
    private let ledger: AccessLedger
    private let now: () -> Date
    private var running = false

    public init(
        sync: AccessSyncing, account: AccessAccount, identity: DeviceIdentity, ledger: AccessLedger,
        now: @escaping () -> Date = Date.init
    ) {
        self.sync = sync
        self.account = account
        self.identity = identity
        self.ledger = ledger
        self.now = now
    }

    private var nowMs: Int64 { Int64(now().timeIntervalSince1970 * 1000) }

    /// One cycle over the servers this device knows. A cycle that starts while another runs does nothing.
    @discardableResult
    public func run(servers: [any AccessServer]) async throws -> Outcome {
        guard !running else { return Outcome() }
        running = true
        defer { running = false }
        var outcome = Outcome()

        guard let session = try await account.restoreSession() else { return outcome }
        let me = try await account.me()
        guard me.device.approved else { return outcome }
        let accountID = session.user.id

        outcome.revoked = await finishRevocations(accountID: accountID, servers: servers)

        guard let payload = try await sync.pull() else { return outcome }
        let byServer = Dictionary(
            servers.map { ($0.accessServerID.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(payload.servers.map { $0.id.uuidString.lowercased() })

        var grants: [AccessGrant] = []
        var answered: [AccessKey: Int64] = [:]
        var dropped: [AccessKey: Int64] = [:]

        // Grants that were made but never written (the write failed): write them now, once.
        for issue in ledger.issues where issue.accountID == accountID {
            if let pending = issue.pending {
                grants.append(pending)
                answered[AccessKey(deviceID: issue.deviceID, serverID: issue.serverID)] = issue.requestAt
            }
        }

        for request in payload.accessRequests where request.deviceID != me.device.id {
            let key = request.key
            if let issue = ledger.issue(
                accountID: accountID, deviceID: request.deviceID, serverID: request.serverID, requestAt: request.at)
            {
                // Answered already (this cycle's pending write, or an earlier one): never again.
                answered[key] = max(answered[key] ?? 0, issue.requestAt)
                continue
            }
            if payload.accessGrants.contains(where: { $0.key == key && $0.at >= request.at }) { continue }
            guard let asking = me.devices.first(where: { $0.id == request.deviceID && $0.approved }) else {
                // A device that is not in the account, or not approved, gets nothing; the request ages out.
                continue
            }
            guard known.contains(request.serverID), let server = byServer[request.serverID], server.isReachable else {
                outcome.waiting += 1
                continue
            }
            // The key the answer is sealed to: the one the asking device wrote in its request (inside the encrypted
            // blob), which must agree with the account's list when that lists keys.
            let recipient = request.publicKey ?? asking.publicKey
            if let listed = asking.publicKey, let written = request.publicKey, listed != written {
                outcome.failed += 1
                continue
            }
            guard let recipient, Self.isPublicKey(recipient) else {
                outcome.failed += 1
                continue
            }
            do {
                let issued = try await server.issueDeviceToken(
                    name: Self.deviceName(asking.name), platform: Self.platform(asking.platform),
                    noiseKey: request.noiseKey)
                let sealed: String
                do {
                    sealed = try DeviceTokenSeal.seal(
                        token: issued.token, forPublicKey: recipient, sender: identity,
                        accountID: accountID, deviceID: request.deviceID, serverID: request.serverID)
                } catch {
                    try? await server.revokeDeviceRow(issued.deviceId)
                    outcome.failed += 1
                    continue
                }
                let grant = AccessGrant(
                    deviceID: request.deviceID, serverID: request.serverID, sealed: sealed, at: nowMs)
                ledger.record(
                    AccessLedger.Issue(
                        accountID: accountID, deviceID: request.deviceID, deviceName: asking.name,
                        serverID: request.serverID, requestAt: request.at, rowID: issued.deviceId, issuedAt: nowMs,
                        pending: grant))
                grants.append(grant)
                answered[key] = max(answered[key] ?? 0, request.at)
                outcome.issued += 1
            } catch let error as RPCError where error.code == RPCError.invalidParams {
                // The daemon will never take this request (a broken key): drop it instead of asking every cycle.
                dropped[key] = max(dropped[key] ?? 0, request.at)
                outcome.failed += 1
            } catch {
                outcome.failed += 1
            }
        }

        let removals = answered.merging(dropped) { max($0, $1) }
        guard !grants.isEmpty || !removals.isEmpty else { return outcome }
        try await sync.update { payload in
            for grant in grants {
                payload.accessGrants.removeAll { $0.key == grant.key }
                payload.accessGrants.append(grant)
            }
            payload.accessRequests.removeAll { request in
                guard let at = removals[request.key] else { return false }
                return request.at <= at
            }
        }
        for issue in ledger.issues where issue.pending != nil && grants.contains(where: { $0.sealed == issue.pending?.sealed }) {
            ledger.markWritten(issue)
        }
        await replaceOldRows(accountID: accountID, byServer: byServer)
        return outcome
    }

    // MARK: revoking

    /// The device `deviceID` ("`name`") left the account: its rows on the servers go. Servers that are not reachable
    /// now are cleaned by later cycles (`run`).
    @discardableResult
    public func revoke(deviceID: String, name: String, servers: [any AccessServer]) async -> Int {
        guard let accountID = try? await account.restoreSession()?.user.id else { return 0 }
        ledger.addRevocation(
            AccessLedger.Revocation(
                accountID: accountID, deviceID: deviceID, deviceName: name, requestedAt: nowMs, done: []))
        let count = await finishRevocations(accountID: accountID, servers: servers)
        // Its open requests and grants are of no use any more.
        _ = try? await sync.update { payload in
            payload.accessRequests.removeAll { $0.deviceID == deviceID }
            payload.accessGrants.removeAll { $0.deviceID == deviceID }
        }
        return count
    }

    /// Cleans the servers that are reachable for every open revocation of `accountID`.
    private func finishRevocations(accountID: String, servers: [any AccessServer]) async -> Int {
        ledger.dropOldRevocations(nowMs: nowMs)
        var revoked = 0
        for revocation in ledger.revocations where revocation.accountID == accountID {
            for server in servers where server.isReachable {
                let serverID = server.accessServerID.uuidString.lowercased()
                if revocation.done.contains(serverID) { continue }
                do {
                    revoked += try await removeRows(of: revocation, on: server, serverID: serverID)
                    ledger.markDone(revocation, serverID: serverID)
                } catch {
                    // Not reachable after all: the next cycle tries again.
                }
            }
        }
        return revoked
    }

    /// Revokes the rows this device issued for the device (by the id it kept), and, for a row it did not issue (another
    /// Mac answered), the rows with the device's name that are not the caller's own.
    private func removeRows(of revocation: AccessLedger.Revocation, on server: any AccessServer, serverID: String) async throws -> Int {
        var count = 0
        let mine = ledger.issues.filter {
            $0.accountID == revocation.accountID && $0.deviceID == revocation.deviceID && $0.serverID == serverID
        }
        let rows = try await server.deviceRows()
        var revokedIDs = Set<String>()
        for issue in mine {
            if rows.contains(where: { $0.id == issue.rowID }) {
                try await server.revokeDeviceRow(issue.rowID)
                count += 1
            }
            revokedIDs.insert(issue.rowID)
            ledger.remove(rowID: issue.rowID, serverID: serverID)
        }
        // Rows that another device of the account issued carry the same name; this device's own row never matches.
        let name = revocation.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            for row in rows
            where row.name == name && row.current != true && !revokedIDs.contains(row.id) && !ledger.isIssuedToOther(rowID: row.id, than: revocation.deviceID) {
                try await server.revokeDeviceRow(row.id)
                count += 1
            }
        }
        return count
    }

    /// A device that asked again (a new request after the old grant was lost) gets a new row; the old one is revoked.
    private func replaceOldRows(accountID: String, byServer: [String: any AccessServer]) async {
        let issues = ledger.issues.filter { $0.accountID == accountID }
        for issue in issues {
            let newer = issues.contains {
                $0.deviceID == issue.deviceID && $0.serverID == issue.serverID && $0.requestAt > issue.requestAt
                    && $0.pending == nil
            }
            guard newer, let server = byServer[issue.serverID], server.isReachable else { continue }
            try? await server.revokeDeviceRow(issue.rowID)
            ledger.remove(rowID: issue.rowID, serverID: issue.serverID)
        }
    }

    // MARK: helpers

    static func isPublicKey(_ base64: String) -> Bool {
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else { return false }
        return (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)) != nil
    }

    static func deviceName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Device" : String(trimmed.prefix(100))
    }

    /// `ios` and `macos` pass; anything else becomes a lower-case word the daemon accepts.
    static func platform(_ platform: String) -> String {
        let cleaned = platform.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return cleaned.isEmpty ? "ios" : String(cleaned.prefix(32))
    }
}

extension AccessLedger {
    /// Whether the row is one this device issued for a device other than `deviceID`: such a row is not touched by name.
    func isIssuedToOther(rowID: String, than deviceID: String) -> Bool {
        issues.contains { $0.rowID == rowID && $0.deviceID != deviceID }
    }
}
