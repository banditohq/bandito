import Foundation

/// What the screen shows for a server of the account.
public struct AccessServerState: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        /// This device holds a token: the server is connected (or being connected) through the sink.
        case connected
        /// A request is in the blob and no device has answered yet ("waiting for the Mac").
        case waitingForMac
        /// The server has no relay or direct access written by any device, so there is nothing to ask for.
        case noRemoteAccess
        /// The person removed this server on this device: it is not asked for again until they show it.
        case hidden
    }

    public var id: UUID
    public var name: String
    public var status: Status
    public var phone: SyncedPhone?

    public init(id: UUID, name: String, status: Status, phone: SyncedPhone?) {
        self.id = id
        self.name = name
        self.status = status
        self.phone = phone
    }
}

/// The asking side of "servers follow you". Each cycle: opens the grants that were made for this device and hands the
/// tokens to the `ServerAccessSink`; adds a request for each server of the account that has a way in (`phone`) but no
/// token here; removes the requests and grants that are done.
///
/// It writes the blob only when something changed, so an idle cycle costs one read.
@MainActor
public final class AccessRequester {
    private let sync: AccessSyncing
    private let account: AccessAccount
    private let identity: DeviceIdentity
    private let sink: ServerAccessSink
    private let noiseKeys: ServerNoiseKeyStore
    private let dismissed: DismissedServers
    private let defaults: UserDefaults
    private let now: () -> Date
    private var running = false

    /// After a grant that would not open, the same server is not asked for again for this long.
    static let badGrantBackoffMs: Int64 = 10 * 60 * 1000

    public init(
        sync: AccessSyncing, account: AccessAccount, identity: DeviceIdentity, sink: ServerAccessSink,
        noiseKeys: ServerNoiseKeyStore, defaults: UserDefaults = .standard, dismissed: DismissedServers? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.dismissed = dismissed ?? DismissedServers(defaults: defaults)
        self.sync = sync
        self.account = account
        self.identity = identity
        self.sink = sink
        self.noiseKeys = noiseKeys
        self.defaults = defaults
        self.now = now
    }

    private var nowMs: Int64 { Int64(now().timeIntervalSince1970 * 1000) }

    private func backoffKey(_ accountID: String, _ serverID: String) -> String {
        "account.access.badGrant.\(accountID).\(serverID)"
    }

    /// One cycle. Returns the state of every server of the account for the screen; an empty list when this device is
    /// signed out, not approved yet, or the account has no data. A cycle that starts while another runs does nothing.
    @discardableResult
    public func run() async throws -> [AccessServerState] {
        guard !running else { return [] }
        running = true
        defer { running = false }

        guard let session = try await account.restoreSession() else { return [] }
        let me = try await account.me()
        guard me.device.approved else { return [] }
        guard let payload = try await sync.pull() else { return [] }
        let accountID = session.user.id
        let myID = me.device.id

        // Keys of the account's devices, when the account lists them: a grant must come from one of them.
        let listed = Set(me.devices.filter(\.approved).compactMap(\.publicKey))
        let senders: Set<String>? = listed.isEmpty ? nil : listed

        var doneGrants = Set<AccessKey>()
        var newRequests: [AccessRequest] = []
        var hiddenIDs = Set<UUID>()
        var states: [AccessServerState] = []

        for server in payload.servers {
            let serverKey = server.id.uuidString.lowercased()
            let key = AccessKey(deviceID: myID, serverID: serverKey)
            var connected = await sink.hasAccess(serverID: server.id, phone: server.phone)
            // Removed here on purpose: nothing is asked for and a grant that arrives anyway is not opened into a server.
            if !connected, dismissed.contains(accountID: accountID, serverID: server.id, phone: server.phone) {
                hiddenIDs.insert(server.id)
                if payload.accessGrants.contains(where: { $0.key == key }) { doneGrants.insert(key) }
                states.append(AccessServerState(id: server.id, name: server.name, status: .hidden, phone: server.phone))
                continue
            }

            if let grant = payload.accessGrants.first(where: { $0.key == key }) {
                if connected {
                    doneGrants.insert(key)
                } else {
                    do {
                        let opened = try DeviceTokenSeal.open(
                            sealed: grant.sealed, with: identity, accountID: accountID, deviceID: myID,
                            serverID: serverKey, expectedSenders: senders)
                        // The address and the pins are the grant's (the daemon's own answer), never the blob's hint.
                        try await sink.receive(
                            ServerAccess(
                                serverID: server.id, name: server.name, phone: opened.phone, deviceToken: opened.token))
                        connected = true
                        doneGrants.insert(key)
                    } catch is DeviceTokenSealError {
                        // It will never open: forget it and do not ask again at once, or two devices could loop.
                        doneGrants.insert(key)
                        defaults.set(nowMs, forKey: backoffKey(accountID, serverKey))
                    } catch {
                        // The sink could not take it: the grant stays, the next cycle tries again.
                    }
                }
            }

            if connected {
                states.append(AccessServerState(id: server.id, name: server.name, status: .connected, phone: server.phone))
                continue
            }
            guard let phone = server.phone, phone.isReachable else {
                states.append(AccessServerState(id: server.id, name: server.name, status: .noRemoteAccess, phone: server.phone))
                continue
            }
            states.append(AccessServerState(id: server.id, name: server.name, status: .waitingForMac, phone: phone))
            let asked = payload.accessRequests.contains { $0.key == key }
            let granted = payload.accessGrants.contains { $0.key == key } && !doneGrants.contains(key)
            if asked || granted { continue }
            let backoff = defaults.object(forKey: backoffKey(accountID, serverKey)) as? Int64 ?? 0
            if backoff > 0, nowMs - backoff < Self.badGrantBackoffMs { continue }
            guard let noise = try? noiseKeys.publicKey(for: server.id) else { continue }
            newRequests.append(
                AccessRequest(
                    deviceID: myID, serverID: serverKey, noiseKey: noise, publicKey: identity.publicKeyBase64, at: nowMs))
        }

        // Requests of this device for servers it now holds a token for (or that left the account) are done.
        var doneRequests = Set<AccessKey>()
        let accountServers = Set(payload.servers.map { $0.id.uuidString.lowercased() })
        for request in payload.accessRequests where request.deviceID == myID {
            let id = UUID(uuidString: request.serverID)
            let phone = payload.servers.first { $0.id == id }?.phone
            let held = id != nil ? await sink.hasAccess(serverID: id!, phone: phone) : false
            if held || (id != nil && hiddenIDs.contains(id!)) || !accountServers.contains(request.serverID) { doneRequests.insert(request.key) }
        }

        guard !doneGrants.isEmpty || !newRequests.isEmpty || !doneRequests.isEmpty else { return states }
        let additions = newRequests
        let removeGrants = doneGrants
        let removeRequests = doneRequests.union(doneGrants)
        try await sync.update { payload in
            payload.accessGrants.removeAll { $0.deviceID == myID && removeGrants.contains($0.key) }
            payload.accessRequests.removeAll { $0.deviceID == myID && removeRequests.contains($0.key) }
            for request in additions where !payload.accessRequests.contains(where: { $0.key == request.key }) {
                payload.accessRequests.append(request)
            }
        }
        return states
    }
}
