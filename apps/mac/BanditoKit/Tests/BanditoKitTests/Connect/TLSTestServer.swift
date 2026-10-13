import Foundation
import Network
import Security

@testable import BanditoKit

/// A WebSocket server with TLS on loopback, for the tests of the direct connection: two throw-away self-signed
/// certificates made for these tests only (RSA 2048, valid for 100 years, no use anywhere else), a JSON-RPC answer for
/// `daemon.hello` and `pair.redeem`, and a silent TCP listener that never answers (a timeout).
final class TLSTestServer: @unchecked Sendable {
    /// SHA-256 of the certificate of `.a` and of `.b`.
    static let fingerprintA = "1745bdf700f4af22b0837fb4eec6d6fa00ad1d2955b6b20a829baae31044ae1c"
    static let fingerprintB = "59fb660ece503134403a78f563176cd8adf00feac58ff2f44b0adac3fe8e49e7"
    /// The server needs macOS 15 (an in-memory identity); the tests that use it are skipped on older systems.
    static var isSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    static let validCode = "otter-lava-mint-orbit-crane-fig"
    static let token = "bdt_test_token_from_the_fake_server"

    enum Certificate: String {
        case a, b

        var fingerprint: String { self == .a ? TLSTestServer.fingerprintA : TLSTestServer.fingerprintB }
        fileprivate var base64: String { self == .a ? TLSTestServer.p12A : TLSTestServer.p12B }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tls-test-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var redeemCalls = 0
    private var revokeCalls = 0

    /// The port the listener got.
    private(set) var port = 0
    /// How many `pair.redeem` calls came in.
    var redeems: Int {
        lock.lock()
        defer { lock.unlock() }
        return redeemCalls
    }

    /// Listens on 127.0.0.1 with `certificate`. `tls` false makes a plain TCP listener that accepts and never answers.
    init(certificate: Certificate = .a, tls: Bool = true) throws {
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            let identity = try Self.identity(base64: certificate.base64)
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identity)!)
            parameters = NWParameters(tls: options)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = false
            parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
            if tls { self.receive(on: connection) }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = Int(port)
    }

    /// How many `devices.revoke` calls came in.
    var revokes: Int {
        lock.lock()
        defer { lock.unlock() }
        return revokeCalls
    }

    var address: String { "127.0.0.1:\(port)" }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .ping {
                let pong = NWProtocolWebSocket.Metadata(opcode: .pong)
                let reply = NWConnection.ContentContext(identifier: "pong", metadata: [pong])
                connection.send(content: data ?? Data(), contentContext: reply, isComplete: true, completion: .idempotent)
            } else if let data, let text = String(data: data, encoding: .utf8) {
                self.answer(text, on: connection)
            }
            self.receive(on: connection)
        }
    }

    private func answer(_ text: String, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let id = object["id"], let method = object["method"] as? String
        else { return }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "daemon.hello":
            reply["result"] = ["name": "bandito", "version": "0.1.15", "hostname": "fake", "authenticated": false]
        case "pair.redeem":
            lock.lock()
            redeemCalls += 1
            lock.unlock()
            let params = object["params"] as? [String: Any]
            if (params?["code"] as? String) == Self.validCode {
                reply["result"] = [
                    "token": Self.token,
                    "device": ["id": "dev-1", "name": params?["device_name"] ?? "", "created_at": 1],
                ]
            } else {
                reply["error"] = ["code": -32001, "message": "invalid or expired code"]
            }
        case "devices.list":
            reply["result"] = [["id": "dev-1", "name": "iPhone", "created_at": 1, "current": true]]
        case "devices.revoke":
            lock.lock()
            revokeCalls += 1
            lock.unlock()
            reply["result"] = ["revoked": true]
        default:
            reply["error"] = ["code": -32601, "message": "unknown method"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "reply", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private static func identity(base64: String) throws -> SecIdentity {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: "test"]
        // Without it the identity would land in the login Keychain of whoever runs the tests.
        guard #available(macOS 15, *) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUnimplemented)) }
        options[kSecImportToMemoryOnly as String] = true
        let status = SecPKCS12Import(Data(base64Encoded: base64)! as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
            let identity = first[kSecImportItemIdentity as String]
        else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // swiftlint:disable:next force_cast
        return identity as! SecIdentity
    }

    private static let p12A = "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"
    private static let p12B = "MIIJYQIBAzCCCR8GCSqGSIb3DQEHAaCCCRAEggkMMIIJCDCCA78GCSqGSIb3DQEHBqCCA7AwggOsAgEAMIIDpQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQIrsmWIk8i9A0CAggAgIIDeM5jt869xFEy0bYaoN5uJQ1+FufIEUOqws1GKBJjXRyJK65/HWu/zCvgJJ3TgcOeaacsjuDg+hEAxH2/qY88X7WmCx9M/WuVQOTVh29zgu3ciuDJFQH3eJK+JyeRhxAogqYDW4zQ1MSaeWXnRI63ngDpLU/caTL83sqHSR7kL34Q3wP3DEVg6ZTM0YynfEdJEP5GrJJK4gUL9m8j0EHb9IRjsHX8g97t962DRyHynhQnDJuTzxOv5O7yHPv8LhUIvnP/5zA5dXf6g5dYKeWjzWl9h+sBqmLMafi18GaPsWeXGMaBAROecmulHvvt1E5QPmyR9UbwloTmWZQ2wJUSL7+m0tSlTGYlkprNdN3IiS/euoFDrDshwOQBJtuuhUdwMbVw2+upFVyU5BbSD0O6RfuVHWf5rybqpJy09ovpfIf0TK6EslN2krFC6B9XmqAdB5eUQx5Jf15XUfWQjZ6ytSWqzg8SQPYhLQqaLRCxDNZzq9VRZLBSv/5OEQzdVKi/TCDrTtaANnVLm2NdomBb7zI8vAOZBnzlT6rf8A7WzXuC4iI9FKzWWTYD4crm/kRf9awo0SLoTtMjs5LpqME22rLlXYR6/MZg8EXdJzxMCjIFTT1sFXiiwyS1Q1UBcRuOPAihb93Pa/p12gf3xCZ4QDMVVB/6VETmEsDrowSrDhF05EIqR/pK0qa/+IYIhcVb4X+93tk6qu2oU3XMwWAJztcyfVK5bd0ii5XB1V3jY3pZKKeGLt1W+fF0k1J01F7pqNTcYiRMKETgS8/kjZzEzOzqbjsPw+Tn2FGWmVJ35miwZfQ8kw1TzvG4unfNsHqHw1edjaX885q3aIocRSX/RJmrJBMqviUYPKxi+fDZdfC70dPRpl+ug0w/v6/AupYVO0T9VSZT3x29sKLSu+ZnYYRnFIOuhdQXX+Lr+BuLZEhsptpbUIikPJXmghbYWd4HYqAFi4p888UBDO8j2kBuxBuT3QxcqTw3cWWafABXzvsRxE2iTWbCLOvVdfBXxocQm6gP5oBMdINxgjlwNYGIKzJU5tjVWAYDeSxQkNic/CX/Lc9U3aNjlAOTHdBzYfXsleeEJ8T7FHNXdPeIBF+g+XmQmFIBVDReZ8Az4FM7Nplhk4Z+7UuaI2HjljsI8JrGBJNzXH2XllrU+ei15UnrlD1uYz8cPiPacDCCBUEGCSqGSIb3DQEHAaCCBTIEggUuMIIFKjCCBSYGCyqGSIb3DQEMCgECoIIE7jCCBOowHAYKKoZIhvcNAQwBAzAOBAi0RhAX0ZvR9wICCAAEggTIVoob1ZLi5harkprx22cHB0tXCCIU5jUtga5fpTrsr1WrA0ZAawzqjLLldBW/b2BllGfmcEPCxrLxjev3F14I+4Mz24ZhZDCYRBSbXk5iOE02LOqz/voA2ANW8PdQl1GPYetN8l9HHyGorpfuYBgKoDoGY5cdNFn64vQsf9KAN5LNa2K4AedBppbjShQ2hNRMj4oC2iJlRM6buIhoVA3JLBDXt2/nAp/IRcaSrmxQpv+N9p/TGxRRysnD8+LTrH/5FknC5XtoNMzd7J5wSWr5jTPWmOKBspRdu5G3IDyZZUt9TpwTw62o94fXjNpbyWjSyj+dtfijxXS6bLWoemmjnYZ80fZIk+BZ5SIDAvGdIV6D0njo1pzUvFQjq8N5hc1C60J0QTirAgqit2NRh6ABN+hQ8xxax065BzoMYh5v2zeCBZWNA+PjQZBQjJkdR9Gdqf5WLK22gSQw7KN3CXHZL7mbzr7oLCdYwosNFqH64LZ0i2l002HUln1dqeB0DCLFddchdCOCDms75SYBTM7MS9QqDjJjIAUctUrJynZ7nw2a/EQ2v9uFOtJBgzOn7/pjJmmG8nvWvEaND9Ukb0YZEP2A5MuJqoIhGVn/DCG2fPMMdtFp5n7m/WaTsGtmImeZae/I3NisQxGGHX5IlcjbLhOdPSt2/kW1V+QWT1wv0pCuG375b6FMuKubaI/MbXlYGnR9AWalm33eyTVIsZmADLzkVGzl97JJ3CGo/fIxK/XN4cV5mqVyWQ6AtBdcFrV10VavGAVDtuWAtS+RQZ/gKUb8q6cXzWW58NOxDzJwwhzFF9TQogZmJ9/EwZIeDVlUw9AN5Z6QOCKZwvs9FKhnW+woKkXhcxFkN+s7IWFZ/TrG0RwUIZ/NrgPVbSlT1ESSKi+iciw+HJ7j1vg7vrAnD/fLMHmPUom8Sqt6ApELKX7wQHXPboBq/exVGt13JG3g4QR8u3es1IWJYP4w3oslzKxSOT2JHPvNHHLxCfzr4hmGDg2gDoM4yn7M+Jx32oVSiAs20wy9lyGJw9frjwxqMdszqrvy0mIK9Fbn1N509dR3bphnySndBzr6ajOH+fTjDn2XqAvVKjHWToABQVrlmMnqggpgGwimJoj5iAfHF47WXKLIhYytipjbAna2D7xslCu5CQEwKKBaer2Bsk8WB5txMC3aS8Jcu5ho1540iCgZ49a2HcisMwS7GQSbXlYAeiGrGqid05KAn0up/qd42qZBrrog5xXkwpRcT4C0Rk/9oKe8Qmvz55OJ9zR2AV+itK1uIoLZijQY4eqRqWTw7/y4pmEvpQ9xVABtniUvNyZGGvMJ02IiuFgWZUHwfgdkkF0MAQwbayvfkhk7AW2nasDGg8ryWsKZYIi/wHkTzNspW6/mjbIsQUjyTSr6krHhuSqD+Xd1no4F/y+8z1RMD07DrtxZbiuwfSuAsfinPvRUZsoWbSuG5m168VgEFt8+BpwXvN7Wtt3B32GxYJE9Ma6h4YDaIZwjvup+cIprd2fA13jvWg5hlFMaJw7elqyEAt2gLDdcTUEvlHfZh6Fn0PPnBVFtNoWYLVH1m+DpfWjVAypOn3zpyhppSDt0pskf5KICZM/Z4WzmgkMMKxWLeeluDgkoJqeCMSUwIwYJKoZIhvcNAQkVMRYEFEqaVyecgmW87CRGEMzHyLTzRDCuMDkwITAJBgUrDgMCGgUABBQujZiMliG0dwI47TkqibrKqO946wQQGYpOcPmdQqsUX2iBi6f4cQICCAA="
}
