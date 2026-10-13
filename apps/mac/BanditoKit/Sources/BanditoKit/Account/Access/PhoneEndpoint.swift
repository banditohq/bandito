import Foundation

// How the account's `phone` record and a device's own server entry turn into each other, and when two entries are the
// same daemon. A daemon is known by its keys: the Noise key (relay) and the certificate (direct), never by an id one
// device made up.

extension SyncedPhone {
    /// The record of a server this device was paired with: its relay route and its direct addresses, both public.
    /// nil for an endpoint that has neither (ssh, a WebSocket address, this Mac's socket).
    public init?(endpoint: ServerEndpoint) {
        var sid: String?
        var host: String?
        var nk: String?
        if let relay = endpoint.relayPart {
            sid = relay.route.sid
            host = relay.route.host
            nk = endpoint.noiseKeyText
        }
        let direct = endpoint.directPart
        guard sid != nil || direct != nil else { return nil }
        self.init(sid: sid, relayHost: host, nk: nk, fp: direct?.fingerprint, hosts: direct?.hosts ?? [])
    }

    /// The way to reach this server from a device that has a device token for it: `.direct` when only direct addresses
    /// are known (the shape pairing by QR makes), `.reachable` when the relay is there. nil when neither is usable.
    public var serverEndpoint: ServerEndpoint? {
        var route: RelayRoute?
        if let sid, let relayHost, let nk, Base64URL.key(nk) != nil, let parsed = RelayRoute.parse("\(relayHost)/\(sid)") {
            route = parsed
        }
        let pin = fp.flatMap { PinnedFingerprint.normalize($0) }
        let addresses = pin == nil ? [] : hosts
        if let route {
            return .reachable(hosts: addresses, fingerprint: addresses.isEmpty ? nil : pin, relay: route, noiseKey: nk)
        }
        if let pin, !addresses.isEmpty { return .direct(hosts: addresses, fingerprint: pin) }
        return nil
    }

    /// Whether `other` describes the same daemon: they share a Noise key or a certificate, and no key they both have
    /// differs.
    public func isSameDaemon(as other: SyncedPhone) -> Bool {
        var shared = false
        for (a, b) in [(nk, other.nk), (fp?.lowercased(), other.fp?.lowercased())] {
            guard let a, let b else { continue }
            if a != b { return false }
            shared = true
        }
        return shared
    }

    /// The same, against the endpoint of a server this device holds.
    public func isSameDaemon(as endpoint: ServerEndpoint) -> Bool {
        guard let mine = SyncedPhone(endpoint: endpoint) else { return false }
        return isSameDaemon(as: mine)
    }

    /// The fields this record lacks, taken from `other` (the same daemon seen by another device).
    func filling(from other: SyncedPhone) -> SyncedPhone {
        var result = self
        if result.sid == nil || result.relayHost == nil || result.nk == nil {
            if let sid = other.sid, let host = other.relayHost, let nk = other.nk, result.sid == nil {
                result.sid = sid
                result.relayHost = host
                result.nk = nk
            }
        }
        if result.fp == nil, let fp = other.fp, !other.hosts.isEmpty {
            result.fp = fp
            result.hosts = other.hosts
        }
        return result
    }
}

extension ServerAccess {
    /// The server entry this access makes on the device: the id the account gave it (so every device counts one server
    /// as one), the endpoint from the record, the token, and the Noise key this device made for it. nil when the record
    /// has no usable way in.
    public func serverConfig(noiseKey: Data) -> ServerConfig? {
        guard let endpoint = phone.serverEndpoint else { return nil }
        let secret = endpoint.relayPart == nil ? nil : Base64URL.encode(noiseKey)
        return ServerConfig(id: serverID, name: name, endpoint: endpoint, token: deviceToken, noiseSecret: secret)
    }
}

/// Publishing the servers a device was paired with by link into the account's blob, so the account's other devices can
/// ask for access. The endpoint of such an entry is `.local(deviceID:)` of the device that added it: a build that does not
/// know the entry still reads it, and a build that knows reads its `phone` record.
public enum PairedServerPublishing {
    /// The entries to add for `configs`: servers with a phone record that the blob does not have, by id or as the same daemon.
    public static func missing(configs: [ServerConfig], in payload: SyncPayload, deviceID: String, now: Date = Date()) -> [SyncedServer] {
        var added: [SyncedServer] = []
        for config in configs {
            guard let phone = SyncedPhone(endpoint: config.endpoint) else { continue }
            if payload.servers.contains(where: { $0.id == config.id }) { continue }
            if payload.servers.contains(where: { $0.phone?.isSameDaemon(as: phone) == true }) { continue }
            if added.contains(where: { $0.phone?.isSameDaemon(as: phone) == true }) { continue }
            added.append(
                SyncedServer(
                    id: config.id, name: config.name, endpoint: .local(deviceID: deviceID),
                    addedAt: Int64(now.timeIntervalSince1970 * 1000), phone: phone))
        }
        return added
    }

    /// Adds `missing` to the blob (read, changed and written again on a version conflict). Does nothing, and writes
    /// nothing, when there is nothing to add. Returns how many entries were added.
    @MainActor
    @discardableResult
    public static func publish(configs: [ServerConfig], to sync: AccessSyncing, deviceID: String) async throws -> Int {
        let current = try await sync.pull() ?? SyncPayload()
        guard !missing(configs: configs, in: current, deviceID: deviceID).isEmpty else { return 0 }
        var count = 0
        try await sync.update { payload in
            let more = missing(configs: configs, in: payload, deviceID: deviceID)
            payload.servers.append(contentsOf: more)
            count = more.count
        }
        return count
    }
}

extension SyncPayload {
    /// One entry per daemon: two entries with the same Noise key or certificate are one server that two devices added.
    /// The entry with the richer endpoint stays (ssh, then a WebSocket address, then a link-paired one), the lower id
    /// among equals, and it takes what the other knew about how to reach it.
    func collapsingSameDaemon() -> SyncPayload {
        func rank(_ server: SyncedServer) -> Int {
            switch server.endpoint {
            case .ssh: 0
            case .webSocket: 1
            case .local: 2
            }
        }
        func before(_ a: SyncedServer, _ b: SyncedServer) -> Bool {
            rank(a) != rank(b) ? rank(a) < rank(b) : a.id.uuidString < b.id.uuidString
        }
        var kept: [SyncedServer] = []
        for server in servers {
            guard let phone = server.phone else {
                kept.append(server)
                continue
            }
            if let index = kept.firstIndex(where: { $0.phone?.isSameDaemon(as: phone) == true }) {
                var winner = before(server, kept[index]) ? server : kept[index]
                let loser = before(server, kept[index]) ? kept[index] : server
                if let mine = winner.phone, let theirs = loser.phone { winner.phone = mine.filling(from: theirs) }
                kept[index] = winner
            } else {
                kept.append(server)
            }
        }
        var result = self
        result.servers = kept
        return result
    }
}
