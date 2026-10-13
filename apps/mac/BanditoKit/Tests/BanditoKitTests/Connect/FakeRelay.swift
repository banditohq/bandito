import CryptoKit
import Foundation
import Network

@testable import BanditoKit

/// A relay and a daemon in one, on loopback, for tests: a plain WebSocket at `/v1/client/<sid>` that runs the daemon's
/// side of the session (Noise responder, `{"auth"}` / `{"pair"}`, a few RPC methods) like `daemon/src/relay.rs`.
final class FakeRelay: @unchecked Sendable {
    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let validCode = "otter-lava-mint-orbit-crane-fig"
    static let token = "bdt_fake_relay_token"

    let daemonKey = Curve25519.KeyAgreement.PrivateKey()
    private(set) var port = 0

    /// What the next connections do instead of serving: close with this code at once (a limit), or refuse the first
    /// message with this reason.
    var closeCodeOnOpen: Int?
    var refusal: String?
    /// Never answers message 1 (a relay or daemon that hangs).
    var silent = false
    /// A text frame the relay sends after the handshake before anything else.
    var pingAfterHandshake = false

    private let listener: NWListener
    fileprivate let queue = DispatchQueue(label: "fake-relay")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var pairedKeys: [Data] = []
    private var _redeemed: [(name: String, noiseKey: String?)] = []
    private var _frames: [String] = []
    private var _texts: [String] = []

    var daemonPublicKey: Data { daemonKey.publicKey.rawRepresentation }
    var redeemed: [(name: String, noiseKey: String?)] { lock.withLock { _redeemed } }
    var frames: [String] { lock.withLock { _frames } }
    var texts: [String] { lock.withLock { _texts } }
    var route: RelayRoute { RelayRoute(host: "127.0.0.1:\(port)", sid: Self.sid) }

    init() throws {
        let parameters = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = false
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            let session = Session(relay: self, connection: connection)
            session.receive()
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = Int(port)
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections = [] }
            return connections
        }
        for connection in open { connection.cancel() }
    }

    fileprivate func note(frame: String) { lock.withLock { _frames.append(frame) } }
    fileprivate func note(text: String) { lock.withLock { _texts.append(text) } }
    fileprivate func note(redeem: (String, String?)) { lock.withLock { _redeemed.append(redeem) } }
    func learn(key: Data) { lock.withLock { pairedKeys.append(key) } }
    fileprivate func knows(key: Data) -> Bool { lock.withLock { pairedKeys.contains(key) } }

    /// One phone's stream.
    fileprivate final class Session: @unchecked Sendable {
        let relay: FakeRelay
        let connection: NWConnection
        var responder: NoiseResponder
        var transport: NoiseTransport?
        var joiner = NoiseFraming.Joiner()
        var stage = 0
        var phoneKey: Data?
        var paired = false

        init(relay: FakeRelay, connection: NWConnection) {
            self.relay = relay
            self.connection = connection
            responder = NoiseResponder(staticKey: relay.daemonKey)
        }

        func receive() {
            connection.receiveMessage { [self] data, context, _, error in
                guard error == nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                switch metadata?.opcode {
                case .text:
                    if let data, let text = String(data: data, encoding: .utf8) {
                        relay.note(text: text)
                        if text == "ping" { sendText("pong") }
                    }
                case .binary:
                    if let data { handle(binary: data) }
                case .close:
                    return
                default:
                    break
                }
                receive()
            }
        }

        func handle(binary data: Data) {
            if relay.silent { return }
            if stage == 0, let code = relay.closeCodeOnOpen {
                close(code)
                return
            }
            do {
                if stage == 0 {
                    _ = try responder.readMessage1(data)
                    phoneKey = responder.remoteStatic?.rawRepresentation
                    let (reply, session) = try responder.writeMessage2(payload: Data(#"{"v":1}"#.utf8))
                    transport = session
                    stage = 1
                    sendBinary(reply)
                    if relay.pingAfterHandshake { sendText("ping") }
                    return
                }
                guard var t = transport else { return }
                let plain = try t.decrypt(data)
                transport = t
                guard let frame = try joiner.push(plain) else { return }
                let text = String(decoding: frame, as: UTF8.self)
                if stage == 1 {
                    stage = 2
                    try first(text)
                } else {
                    try rpc(text)
                }
            } catch {
                connection.cancel()
            }
        }

        func first(_ text: String) throws {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
            if let reason = relay.refusal {
                try refuse(reason)
            } else if let token = object["auth"] as? String {
                if token == FakeRelay.token, let key = phoneKey, relay.knows(key: key) { paired = true } else { try refuse("unauthorized") }
            } else if object["pair"] as? Bool == true {
                paired = false
            } else {
                try refuse("bad_request")
            }
        }

        func refuse(_ reason: String) throws {
            try sendEncrypted(#"{"error":"\#(reason)"}"#)
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in connection.cancel() }
        }

        var queue: DispatchQueue { relay.queue }

        func rpc(_ text: String) throws {
            relay.note(frame: text)
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let id = object["id"], let method = object["method"] as? String
            else { return }
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            let params = object["params"] as? [String: Any]
            switch method {
            case "daemon.hello":
                reply["result"] = ["name": "bandito", "version": "0.1.16", "hostname": "relay-fake", "authenticated": paired]
            case "pair.redeem":
                if params?["code"] as? String == FakeRelay.validCode, !paired, let key = phoneKey {
                    // The daemon stores the phone's key from `noise_key`, which must be the key this stream speaks with.
                    let sent = params?["noise_key"] as? String
                    if sent != Base64URL.encode(key) {
                        reply["error"] = ["code": -32602, "message": "noise_key does not match the stream"]
                    } else {
                        relay.learn(key: key)
                        relay.note(redeem: (params?["device_name"] as? String ?? "", sent))
                        reply["result"] = [
                            "token": FakeRelay.token,
                            "device": ["id": "dev-1", "name": params?["device_name"] ?? "", "created_at": 1],
                        ]
                    }
                } else {
                    reply["error"] = ["code": -32001, "message": "invalid or expired code"]
                }
            case "big.echo":
                reply["result"] = ["text": String(repeating: "x", count: 150_000)]
            case "devices.list":
                reply["result"] = [["id": "dev-1", "name": "iPhone", "created_at": 1, "current": true]]
            case "devices.revoke":
                reply["result"] = ["revoked": true]
            default:
                if !paired {
                    reply["error"] = ["code": -32001, "message": "unauthorized"]
                } else {
                    reply["result"] = ["ok": true]
                }
            }
            try sendEncrypted(String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }

        func sendEncrypted(_ text: String) throws {
            guard var t = transport else { return }
            for part in NoiseFraming.split(Data(text.utf8)) { sendBinary(try t.encrypt(part)) }
            transport = t
        }

        func sendBinary(_ data: Data) {
            send(data, opcode: .binary)
        }

        func sendText(_ text: String) {
            send(Data(text.utf8), opcode: .text)
        }

        func close(_ code: Int) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .privateCode(UInt16(code))
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true, completion: .idempotent)
        }

        func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "m", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
