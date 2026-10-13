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
/// - A request is answered only if the key it carries is the key `GET /me` lists for that device id. A server that
///   lists no keys (an older one) gets no answers: `Outcome.updateNeeded` counts them.
/// - One request is answered once: the issue is remembered in the `AccessLedger` before anything else is written, a
///   grant that could not be written is kept there and written by the next cycle, and a request that comes back after
///   it was answered is removed, not answered again. At most one issue per device and server in ten minutes.
/// - Two Macs may answer together: the blob is read again before an issue, the grant never overwrites a newer one of
///   another device, and a row whose grant did not stand is revoked at once.
/// - Every cycle compares the ledger with the account: a row this device issued to a device that is no longer in the
///   account (or not approved) is revoked and forgotten. That covers removal from any device, self-removal and a reset.
///   Rows are found by the id this device kept, never by name.
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
        /// Requests left alone because `GET /me` lists no public key for the device: the account service is older than
        /// this app. Shown in the log as "update bandito.dev support".
        public var updateNeeded = 0
        /// Requests that wait out the ten-minute pause between two issues for one device and server.
        public var cooledDown = 0
        /// Requests another device answered first.
        public var answeredElsewhere = 0
    }

    /// The pause between two issues for one device and server.
    static let issueCooldownMs: Int64 = 10 * 60 * 1000

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

    /// A grant waiting to be written, with what it answers.
    private struct Planned {
        var grant: AccessGrant
        var requestAt: Int64
        var rowID: String
    }

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
        let byServer = Dictionary(
            servers.map { ($0.accessServerID.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let approved = Set(me.devices.filter(\.approved).map(\.id))
        let members = Set(me.devices.map(\.id))

        outcome.revoked = await revokeRowsOfLeftDevices(accountID: accountID, approved: approved, byServer: byServer)

        guard let payload = try await sync.pull() else { return outcome }
        let known = Set(payload.servers.map { $0.id.uuidString.lowercased() })

        var planned: [AccessKey: Planned] = [:]
        var answered: [AccessKey: Int64] = [:]
        var dropped: [AccessKey: Int64] = [:]

        // Grants that were made but never written (the write failed): write them now, once.
        for issue in ledger.issues where issue.accountID == accountID && approved.contains(issue.deviceID) {
            if let pending = issue.pending {
                let key = AccessKey(deviceID: issue.deviceID, serverID: issue.serverID)
                planned[key] = Planned(grant: pending, requestAt: issue.requestAt, rowID: issue.rowID)
                answered[key] = issue.requestAt
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
            // The key the answer is sealed to is the one the account lists for that device id, and the request must
            // carry the same key. An account service that lists none cannot be trusted with this: no answer.
            guard let listed = asking.publicKey else {
                outcome.updateNeeded += 1
                continue
            }
            guard request.publicKey == listed, Self.isPublicKey(listed) else {
                outcome.failed += 1
                continue
            }
            if let last = ledger.lastIssue(accountID: accountID, deviceID: request.deviceID, serverID: request.serverID),
                nowMs - last < Self.issueCooldownMs
            {
                outcome.cooledDown += 1
                continue
            }
            // Another Mac may have answered since this cycle read the blob: read it again before issuing anything.
            if let fresh = try await sync.pull() {
                let stillAsked = fresh.accessRequests.contains { $0.key == key && $0.at == request.at }
                if !stillAsked || fresh.accessGrants.contains(where: { $0.key == key && $0.at >= request.at }) {
                    outcome.answeredElsewhere += 1
                    continue
                }
            }
            do {
                let issued = try await server.issueDeviceToken(
                    name: Self.deviceName(asking.name), platform: Self.platform(asking.platform),
                    noiseKey: request.noiseKey)
                let sealed: String
                do {
                    sealed = try DeviceTokenSeal.seal(
                        token: issued.token, forPublicKey: listed, sender: identity,
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
                planned[key] = Planned(grant: grant, requestAt: request.at, rowID: issued.deviceId)
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
        // Requests and grants of devices that left the account are of no use any more.
        let hasStale = payload.accessRequests.contains { !members.contains($0.deviceID) }
            || payload.accessGrants.contains { !members.contains($0.deviceID) }

        let removals = answered.merging(dropped) { max($0, $1) }
        guard !planned.isEmpty || !removals.isEmpty || hasStale else { return outcome }
        let writes = planned
        let stored = try await sync.update { payload in
            for (key, plan) in writes {
                // Never over a grant that answers the same request and is not ours: that one stands.
                if let existing = payload.accessGrants.first(where: { $0.key == key }),
                    existing.at >= plan.requestAt, existing.sealed != plan.grant.sealed
                {
                    continue
                }
                payload.accessGrants.removeAll { $0.key == key }
                payload.accessGrants.append(plan.grant)
            }
            payload.accessRequests.removeAll { request in
                if !members.contains(request.deviceID) { return true }
                guard let at = removals[request.key] else { return false }
                return request.at <= at
            }
            payload.accessGrants.removeAll { !members.contains($0.deviceID) }
        }
        // A grant that did not stand (another Mac's won) leaves a row nobody holds: revoke it.
        for (key, plan) in planned {
            let standing = stored.accessGrants.first(where: { $0.key == key })?.sealed == plan.grant.sealed
            guard let issue = ledger.issues.first(where: { $0.rowID == plan.rowID && $0.serverID == key.serverID }) else {
                continue
            }
            if standing {
                ledger.markWritten(issue)
            } else if let server = byServer[key.serverID] {
                try? await server.revokeDeviceRow(plan.rowID)
                ledger.remove(rowID: plan.rowID, serverID: key.serverID)
                outcome.issued -= 1
                outcome.answeredElsewhere += 1
            }
        }
        await replaceOldRows(accountID: accountID, byServer: byServer)
        return outcome
    }

    // MARK: revoking

    /// Revokes the rows this device issued to a device that is no longer in the account, or is not approved: the
    /// account's list is the truth, whoever changed it. Only rows this device issued are touched, found by the row id it
    /// kept. A server that is not reachable is cleaned by a later cycle.
    private func revokeRowsOfLeftDevices(
        accountID: String, approved: Set<String>, byServer: [String: any AccessServer]
    ) async -> Int {
        var count = 0
        for issue in ledger.issues where issue.accountID == accountID && !approved.contains(issue.deviceID) {
            guard let server = byServer[issue.serverID], server.isReachable else { continue }
            do {
                let rows = try await server.deviceRows()
                if rows.contains(where: { $0.id == issue.rowID && $0.current != true }) {
                    try await server.revokeDeviceRow(issue.rowID)
                    count += 1
                }
                ledger.remove(rowID: issue.rowID, serverID: issue.serverID)
            } catch {
                // Not reachable after all: the next cycle tries again.
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
