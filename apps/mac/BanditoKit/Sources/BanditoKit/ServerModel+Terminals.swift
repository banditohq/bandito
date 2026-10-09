import Foundation

// Terminals on the server (docs/ARCHITECTURE.md#terminals): calls, attached streams, and routing of
// the `term.*` notifications to them.

extension ServerModel {
    /// Largest `term.input` payload, decoded (the daemon's limit).
    nonisolated static let maxInputBytes = 64 << 10

    public func terminals() async throws -> [TermInfo] {
        try await rpc().call("term.list", NoParams(), as: [TermInfo].self)
    }

    /// Starts a terminal. `cwd` defaults to the daemon user's home, `command` to the login shell.
    /// `cols` and `rows` are 1…1000.
    public func openTerminal(
        cwd: String? = nil, command: [String]? = nil, title: String? = nil, cols: Int, rows: Int,
        env: [String: String]? = nil
    ) async throws -> TermInfo {
        try Self.checkSize(cols: cols, rows: rows)
        struct P: Encodable {
            var cwd: String?; var command: [String]?; var title: String?; var cols: Int; var rows: Int
            var env: [String: String]?
        }
        return try await rpc().call(
            "term.open", P(cwd: cwd, command: command, title: title, cols: cols, rows: rows, env: env),
            as: TermInfo.self)
    }

    /// Sends keyboard bytes. At most 64 KiB per call; a larger payload is refused before it is sent.
    public func input(_ data: Data, to id: String) async throws {
        guard data.count <= Self.maxInputBytes else {
            throw RPCError(
                code: RPCError.invalidParams,
                message: "input is \(data.count) bytes; the limit is 64 KiB per call")
        }
        struct P: Encodable { var id: String; var data: String }
        try await rpc().call("term.input", P(id: id, data: data.base64EncodedString()))
    }

    /// `cols` and `rows` are 1…1000.
    @discardableResult
    public func resize(_ id: String, cols: Int, rows: Int) async throws -> TermInfo {
        try Self.checkSize(cols: cols, rows: rows)
        struct P: Encodable { var id: String; var cols: Int; var rows: Int }
        return try await rpc().call("term.resize", P(id: id, cols: cols, rows: rows), as: TermInfo.self)
    }

    @discardableResult
    public func rename(_ id: String, title: String) async throws -> TermInfo {
        struct P: Encodable { var id: String; var title: String }
        return try await rpc().call("term.rename", P(id: id, title: title), as: TermInfo.self)
    }

    /// Hangs up the terminal's processes. An attached stream gets `.closed`.
    public func closeTerminal(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("term.close", P(id: id))
    }

    /// Subscribes to a terminal's output. The stream starts with the output from `from` (or the oldest
    /// byte the daemon still keeps) up to now, then follows live output. After a reconnect it continues
    /// from its `nextOffset` by itself. Attaching again to the same id ends the earlier stream.
    public func attach(_ id: String, from: UInt64? = nil) async throws -> TerminalStream {
        struct P: Encodable { var id: String; var from: UInt64? }

        let stream = TerminalStream(id: id)
        terminalStreams.removeValue(forKey: id)?.finish()
        terminalStreams[id] = stream
        do {
            let reply = try await rpc().call("term.attach", P(id: id, from: from), as: AttachReply.self)
            stream.completeAttach(from: from, start: reply.start, data: reply.bytes)
        } catch {
            if terminalStreams[id] === stream { terminalStreams[id] = nil }
            stream.abortAttach(error: error.localizedDescription)
            stream.finish()
            throw error
        }
        return stream
    }

    /// Stops following a terminal. It keeps running on the server; its stream ends.
    public func detach(_ id: String) async throws {
        defer {
            terminalStreams.removeValue(forKey: id)?.finish()
        }
        struct P: Encodable { var id: String }
        try await rpc().call("term.detach", P(id: id))
    }

    // MARK: internals

    static func checkSize(cols: Int, rows: Int) throws {
        guard (1...1000).contains(cols), (1...1000).contains(rows) else {
            throw RPCError(code: RPCError.invalidParams, message: "cols and rows must be 1…1000")
        }
    }

    /// After a (re)connect: re-attaches every stream from its own offset. A terminal the daemon no
    /// longer has ends its stream. Any other failure reports `.error` on the stream and leaves it open
    /// for the next reconnect.
    func reattachTerminals(_ c: RPCClient) async {
        struct P: Encodable { var id: String; var from: UInt64 }
        struct Detach: Encodable { var id: String }
        for (id, stream) in terminalStreams {
            stream.beginAttach()
            do {
                let reply = try await c.call(
                    "term.attach", P(id: id, from: stream.nextOffset), as: AttachReply.self)
                guard terminalStreams[id] === stream else {
                    // Detached while the attach was in flight: the daemon must not keep sending. A stream
                    // replaced by a newer attach is left alone; that attach already holds the subscription.
                    if terminalStreams[id] == nil {
                        _ = try? await c.call("term.detach", Detach(id: id))
                    }
                    continue
                }
                stream.completeAttach(from: stream.nextOffset, start: reply.start, data: reply.bytes)
            } catch let error as RPCError where error.code == RPCError.terminalError && error.message.hasPrefix("not_found") {
                terminalStreams[id] = nil
                stream.terminate()
            } catch {
                stream.abortAttach(error: error.localizedDescription)
            }
        }
    }

    /// Routes one `term.*` notification to the stream of its terminal. Output of a terminal that is
    /// not attached here is dropped.
    func routeNotification(_ n: RPCNotification) {
        guard n.method.hasPrefix("term.") else { return }
        struct Gap: Decodable { var id: String; var lost: UInt64 }
        struct Exit: Decodable { var id: String; var code: Int?; var signal: Int? }
        struct Id: Decodable { var id: String }

        do {
            switch n.method {
            case "term.output":
                let p = try RPCClient.decoder.decode(OutputNotification.self, from: n.params)
                terminalStreams[p.id]?.receiveOutput(offset: p.offset, data: p.bytes)
            case "term.gap":
                let p = try RPCClient.decoder.decode(Gap.self, from: n.params)
                terminalStreams[p.id]?.receiveGap(lost: p.lost)
            case "term.exit":
                let p = try RPCClient.decoder.decode(Exit.self, from: n.params)
                terminalStreams[p.id]?.receiveExit(code: p.code, signal: p.signal)
            case "term.closed":
                let p = try RPCClient.decoder.decode(Id.self, from: n.params)
                terminalStreams.removeValue(forKey: p.id)?.receiveClosed()
            default:
                break
            }
        } catch {
            noteDecodeFailure()
        }
    }

    /// Ends every attached stream (the connection was closed on purpose).
    func finishTerminalStreams() {
        for stream in terminalStreams.values {
            stream.finish()
        }
        terminalStreams.removeAll()
    }
}

/// `term.attach` reply: where the snapshot starts and its bytes.
private struct AttachReply: Decodable {
    var start: UInt64
    var bytes: Data

    private enum Keys: String, CodingKey { case start, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        start = try c.decode(UInt64.self, forKey: .start)
        bytes = try Base64Bytes.decode(try c.decode(String.self, forKey: .data), in: c, key: .data)
    }
}

/// `term.output` notification.
private struct OutputNotification: Decodable {
    var id: String
    var offset: UInt64
    var bytes: Data

    private enum Keys: String, CodingKey { case id, offset, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        offset = try c.decode(UInt64.self, forKey: .offset)
        bytes = try Base64Bytes.decode(try c.decode(String.self, forKey: .data), in: c, key: .data)
    }
}

/// Base64 payloads of terminal and file messages. Invalid base64 is a decoding error.
enum Base64Bytes {
    static func decode<K: CodingKey>(
        _ text: String, in container: KeyedDecodingContainer<K>, key: K
    ) throws -> Data {
        guard let data = Data(base64Encoded: text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "payload is not base64")
        }
        return data
    }
}
