import CryptoKit
import Foundation
import Network

@testable import BanditoKit

/// The Bandito Relay service in a test, on loopback: a plain WebSocket server (its own small HTTP upgrade and framing, so it can
/// read the path and the headers) with the relay's two roles of docs/RELAY.md. `GET /v1/server/<sid>` with
/// `Authorization: Bearer <secret>` is the daemon: its binary messages are `[u32 stream][u8 kind][payload]`. `GET /v1/client/<sid>`
/// is a phone: each gets a stream id, an `open` frame goes to the daemon, its binary messages go to the daemon as `data`
/// frames and the daemon's `data` for that id come back, `close` ends the stream. A phone gets 503 `{"error":"offline"}` while
/// no daemon is connected. The relay never looks inside a message.
final class RelayBridge: @unchecked Sendable {
    let sid: String
    let secret: String
    private(set) var port = 0

    private let listener: NWListener
    private let queue = DispatchQueue(label: "relay-bridge")
    private let lock = NSLock()
    private var server: Peer?
    private var clients: [UInt32: Peer] = [:]
    private var nextStream: UInt32 = 1
    private var peers: [Peer] = []
    private var _streamsOpened = 0

    /// How many phone streams were opened so far.
    var streamsOpened: Int { lock.withLock { _streamsOpened } }
    /// Whether the daemon holds its connection.
    var daemonConnected: Bool { lock.withLock { server != nil } }
    /// Streams of phones that are open now.
    var openStreams: Int { lock.withLock { clients.count } }

    init(sid: String = "abcdefghijklmnopqrstuvwxyz", secret: String = Base64URL.encode(Data((0..<32).map { UInt8($0 &* 7 &+ 3) }))) throws {
        self.sid = sid
        self.secret = secret
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = Peer(connection: connection, bridge: self)
            self.lock.withLock { self.peers.append(peer) }
            connection.start(queue: self.queue)
            peer.receive()
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = Int(port)
    }

    /// The address the daemon is given (`relay.enable`).
    var url: String { "ws://127.0.0.1:\(port)" }
    var route: RelayRoute { RelayRoute(host: "127.0.0.1:\(port)", sid: sid) }

    func stop() {
        listener.cancel()
        let all = lock.withLock { () -> [Peer] in
            defer { peers = []; clients = [:]; server = nil }
            return peers
        }
        for peer in all { peer.connection.cancel() }
    }

    // MARK: routing

    fileprivate func daemonConnected(_ peer: Peer) {
        lock.withLock { server = peer }
    }

    fileprivate func daemonLeft(_ peer: Peer) {
        let streams = lock.withLock { () -> [Peer] in
            guard server === peer else { return [] }
            server = nil
            defer { clients = [:] }
            return Array(clients.values)
        }
        for stream in streams { stream.close(code: 4004) }
    }

    fileprivate func open(client peer: Peer) -> UInt32? {
        let (id, daemon): (UInt32, Peer?) = lock.withLock {
            guard let daemon = server else { return (0, nil) }
            let id = nextStream
            nextStream += 1
            clients[id] = peer
            _streamsOpened += 1
            return (id, daemon)
        }
        guard let daemon else { return nil }
        daemon.send(opcode: 0x2, Self.frame(id, 1, Data(#"{"ip":"127.0.0.1","v":1}"#.utf8)))
        return id
    }

    fileprivate func forward(fromClient id: UInt32, _ payload: Data) {
        let daemon = lock.withLock { server }
        daemon?.send(opcode: 0x2, Self.frame(id, 0, payload))
    }

    fileprivate func clientLeft(_ id: UInt32) {
        let (daemon, known): (Peer?, Bool) = lock.withLock { (server, clients.removeValue(forKey: id) != nil) }
        if known { daemon?.send(opcode: 0x2, Self.frame(id, 2, Data())) }
    }

    fileprivate func fromDaemon(_ message: Data) {
        guard message.count >= 5 else { return }
        let id = message.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let kind = message[message.startIndex + 4]
        let payload = message.dropFirst(5)
        let client = lock.withLock { clients[id] }
        switch kind {
        case 0: client?.send(opcode: 0x2, Data(payload))
        case 2:
            _ = lock.withLock { clients.removeValue(forKey: id) }
            client?.close(code: 4004)
        default: break
        }
    }

    fileprivate static func frame(_ id: UInt32, _ kind: UInt8, _ payload: Data) -> Data {
        var out = Data()
        withUnsafeBytes(of: id.bigEndian) { out.append(contentsOf: $0) }
        out.append(kind)
        out.append(payload)
        return out
    }

    // MARK: one connection

    fileprivate final class Peer: @unchecked Sendable {
        enum Role { case undecided, daemon, client(UInt32) }

        let connection: NWConnection
        unowned let bridge: RelayBridge
        private var buffer = Data()
        private var role = Role.undecided
        private var upgraded = false
        private var fragment = Data()

        init(connection: NWConnection, bridge: RelayBridge) {
            self.connection = connection
            self.bridge = bridge
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 17) { [self] data, _, finished, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    process()
                }
                if error != nil || finished {
                    ended()
                    return
                }
                receive()
            }
        }

        private func ended() {
            switch role {
            case .daemon: bridge.daemonLeft(self)
            case .client(let id): bridge.clientLeft(id)
            case .undecided: break
            }
        }

        private func process() {
            if !upgraded {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                upgrade(head)
                if !upgraded { return }
            }
            while let (opcode, payload) = nextFrame() { handle(opcode, payload) }
        }

        private func upgrade(_ head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ").map(String.init) ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            guard parts.count >= 2, let key = headers["sec-websocket-key"] else { return refuse(400, "{}") }
            let path = parts[1]
            if path == "/v1/server/\(bridge.sid)" {
                guard headers["authorization"] == "Bearer \(bridge.secret)" else { return refuse(401, #"{"error":"unauthorized"}"#) }
                role = .daemon
            } else if path == "/v1/client/\(bridge.sid)" {
                guard bridge.daemonConnected else { return refuse(503, #"{"error":"offline"}"#) }
            } else {
                return refuse(404, "{}")
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            upgraded = true
            if case .daemon = role {
                bridge.daemonConnected(self)
            } else if let id = bridge.open(client: self) {
                role = .client(id)
            } else {
                close(code: 4004)
            }
        }

        private func refuse(_ status: Int, _ body: String) {
            let text = status == 503 ? "Service Unavailable" : status == 401 ? "Unauthorized" : "Error"
            let response = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [connection] _ in connection.cancel() })
        }

        /// One frame from the buffer: opcode and unmasked payload; nil until a whole frame is there.
        private func nextFrame() -> (UInt8, Data)? {
            let bytes = [UInt8](buffer.prefix(14))
            guard bytes.count >= 2 else { return nil }
            let fin = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            let maskLength = masked ? 4 : 0
            guard buffer.count >= offset + maskLength + length else { return nil }
            let mask = masked ? Array(buffer[offset..<offset + 4]) : []
            var payload = Data(buffer[(offset + maskLength)..<(offset + maskLength + length)])
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
            buffer.removeSubrange(..<(offset + maskLength + length))
            if opcode == 0x0 || !fin {
                fragment.append(payload)
                if !fin { return nextFrame() }
                let whole = fragment
                fragment = Data()
                return (opcode == 0x0 ? 0x2 : opcode, whole)
            }
            return (opcode, payload)
        }

        private func handle(_ opcode: UInt8, _ payload: Data) {
            switch (opcode, role) {
            case (0x2, .daemon): bridge.fromDaemon(payload)
            case (0x2, .client(let id)): bridge.forward(fromClient: id, payload)
            case (0x1, _):
                // The relay answers the keepalive itself; any other text is not part of the protocol.
                if String(decoding: payload, as: UTF8.self) == "ping" { send(opcode: 0x1, Data("pong".utf8)) }
            case (0x9, _): send(opcode: 0xA, payload)
            case (0x8, _): connection.cancel()
            default: break
            }
        }

        func send(opcode: UInt8, _ payload: Data) {
            var out = Data([0x80 | opcode])
            if payload.count < 126 {
                out.append(UInt8(payload.count))
            } else if payload.count < 65536 {
                out.append(126)
                out.append(UInt8(payload.count >> 8))
                out.append(UInt8(payload.count & 0xFF))
            } else {
                out.append(127)
                for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((payload.count >> shift) & 0xFF)) }
            }
            out.append(payload)
            connection.send(content: out, completion: .contentProcessed { _ in })
        }

        func close(code: Int) {
            send(opcode: 0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
    }
}
