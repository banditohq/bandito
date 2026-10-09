import Foundation
import Testing

@testable import BanditoKit

/// A socket the test drives: `send` records what the client wrote, `push` feeds what the page sends.
actor MockCDPSocket: CDPSocket {
    private(set) var sent: [String] = []
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private(set) var closed = false

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func receive() async throws -> String {
        if !inbox.isEmpty { return inbox.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() async {
        closed = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func push(_ text: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: text)
        } else {
            inbox.append(text)
        }
    }

    /// The id of the n-th request the client sent (0-based).
    func sentId(_ n: Int) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(sent[n].utf8)) as? [String: Any]
        return try #require(object?["id"] as? Int)
    }
}

@Test func callGetsTheResponseWithTheSameId() async throws {
    let socket = MockCDPSocket()
    let client = CDPClient(socket: socket)
    let task = Task { try await client.send(.navigationHistory) }

    // Wait until the request is written, then answer it.
    while await socket.sent.isEmpty { await Task.yield() }
    let id = try await socket.sentId(0)
    await socket.push(#"{"id":\#(id),"result":{"currentIndex":2,"entries":[]}}"#)

    let result = try await task.value
    #expect(result["currentIndex"]?.numberValue == 2)
    await client.close()
}

@Test func errorReplyThrowsWithCodeAndMessage() async throws {
    let socket = MockCDPSocket()
    let client = CDPClient(socket: socket)
    let task = Task { try await client.send(.reload) }
    while await socket.sent.isEmpty { await Task.yield() }
    let id = try await socket.sentId(0)
    await socket.push(#"{"id":\#(id),"error":{"code":-32000,"message":"Target closed"}}"#)

    do {
        _ = try await task.value
        Issue.record("expected the call to throw")
    } catch let error as CDPError {
        #expect(error == .remote(code: -32000, message: "Target closed"))
    }
    await client.close()
}

@Test func eventsAreDeliveredWhileCallsAreAnswered() async throws {
    let socket = MockCDPSocket()
    let client = CDPClient(socket: socket)
    var events = client.events.makeAsyncIterator()

    await socket.push(
        #"{"method":"Page.screencastFrame","params":{"data":"AA==","metadata":{"deviceWidth":2,"deviceHeight":2},"sessionId":9}}"#)
    let event = await events.next()
    #expect(event?.method == "Page.screencastFrame")
    #expect(event?.params["sessionId"]?.numberValue == 9)
    await client.close()
}

@Test func closeFailsPendingCalls() async throws {
    let socket = MockCDPSocket()
    let client = CDPClient(socket: socket)
    let task = Task { try await client.send(.getTargets) }
    while await socket.sent.isEmpty { await Task.yield() }
    await client.close()

    do {
        _ = try await task.value
        Issue.record("expected the call to throw after close")
    } catch {
        #expect(await socket.closed)
    }
}

@Test func sentRequestsAreNumberedFromOne() async throws {
    let socket = MockCDPSocket()
    let client = CDPClient(socket: socket)
    let first = Task { try await client.send(.reload) }
    while await socket.sent.isEmpty { await Task.yield() }
    let second = Task { try await client.send(.reload) }
    while await socket.sent.count < 2 { await Task.yield() }
    #expect(try await socket.sentId(0) == 1)
    #expect(try await socket.sentId(1) == 2)
    first.cancel()
    second.cancel()
    await client.close()
}
