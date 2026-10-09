import Foundation
import Network
import Testing

@testable import BanditoKit

/// A model whose endpoint is `config` (for tests where the endpoint decides the behaviour).
@MainActor
func makeModel(config: ServerConfig, _ transports: [FakeTransport]) -> (ServerModel, TransportQueue) {
    let queue = TransportQueue(transports)
    let model = ServerModel(
        config: config,
        makeTransport: { _ in queue.next() },
        reconnectDelay: { _ in .milliseconds(10) })
    return (model, queue)
}

/// Parses a JSON object text.
func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

/// The `params` object of a request text.
func paramsOf(_ requestText: String) -> [String: Any] {
    object(requestText)["params"] as? [String: Any] ?? [:]
}

/// An integer that JSONSerialization produced (NSNumber) or nil.
func intValue(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

/// Byte count of a base64 string value, or -1 when it is not valid base64.
func decodedLength(_ value: Any?) -> Int {
    guard let text = value as? String, let data = Data(base64Encoded: text) else { return -1 }
    return data.count
}

/// Collects up to `count` chunks, giving up after `timeout` (returns what arrived).
@MainActor
func collect(_ stream: TerminalStream, count: Int, timeout: Duration = .seconds(3)) async -> [TerminalChunk] {
    let reader = Task { @MainActor () -> [TerminalChunk] in
        var out: [TerminalChunk] = []
        var iterator = stream.chunks.makeAsyncIterator()
        while out.count < count, let chunk = await iterator.next() {
            out.append(chunk)
        }
        return out
    }
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        reader.cancel()
    }
    let result = await reader.value
    watchdog.cancel()
    return result
}

/// Waits until `connection` is ready (fails if it fails first).
func connect(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        let once = Once()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: once.run { k.resume() }
            case .failed(let error): once.run { k.resume(throwing: error) }
            default: break
            }
        }
        connection.start(queue: .global())
    }
}

/// Reads exactly `count` bytes.
func receiveExactly(_ connection: NWConnection, count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error { k.resume(throwing: error) } else { k.resume(returning: data ?? Data()) }
        }
    }
}

/// Files of the test temp folder: a file of `size` bytes with a repeating pattern.
func makeTempFile(size: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bandito-test-\(UUID().uuidString).bin")
    let bytes = Data((0..<size).map { UInt8($0 % 251) })
    try bytes.write(to: url)
    return url
}
