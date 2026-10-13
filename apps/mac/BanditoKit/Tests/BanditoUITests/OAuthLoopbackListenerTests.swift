import BanditoKit
import Foundation
import Network
import Testing

@testable import BanditoUI

/// The real socket, on a free port of 127.0.0.1 (the app uses 45819; a test must not depend on it being free).
@Suite struct OAuthLoopbackListenerTests {
    /// Collects the callback the listener hands over.
    private final class Got: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [OAuthCallback] = []
        func add(_ callback: OAuthCallback) { lock.lock(); items.append(callback); lock.unlock() }
        var all: [OAuthCallback] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func start(state: String = "S1") async throws -> (OAuthLoopbackListener, UInt16, Got) {
        let got = Got()
        let listener = OAuthLoopbackListener(state: state, port: 0) { got.add($0) }
        try await listener.start()
        let port = try #require(listener.boundPort)
        return (listener, port, got)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private func get(_ port: UInt16, _ path: String, language: String? = nil) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        let (data, response) = try await session().data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func waitForCallback(_ got: Got) async {
        for _ in 0..<1000 where got.all.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func theRightCallbackGetsThePageAndIsHandedOverOnce() async throws {
        let (listener, port, got) = try await start()
        defer { listener.stop() }
        let (status, body) = try await get(port, "/callback?code=abc&state=S1&iss=https%3A%2F%2Fmcp.example", language: "ru-RU,ru;q=0.9")
        #expect(status == 200)
        #expect(body.contains("Готово"))
        await waitForCallback(got)
        #expect(got.all == [OAuthCallback(state: "S1", code: "abc", iss: "https://mcp.example", error: nil)])
    }

    @Test func aStrangersRequestsDoNotCloseTheListener() async throws {
        let (listener, port, got) = try await start()
        defer { listener.stop() }
        #expect(try await get(port, "/callback?code=abc&state=WRONG").0 == 400)
        #expect(try await get(port, "/other?state=S1").0 == 404)
        #expect(try await get(port, "/").0 == 404)
        #expect(got.all.isEmpty)
        // The right one still works afterwards.
        #expect(try await get(port, "/callback?code=abc&state=S1").0 == 200)
        await waitForCallback(got)
        #expect(got.all.count == 1)
    }

    @Test func afterTheAnswerTheSocketIsClosed() async throws {
        let (listener, port, got) = try await start()
        defer { listener.stop() }
        _ = try await get(port, "/callback?code=abc&state=S1")
        await waitForCallback(got)
        try? await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) { _ = try await self.get(port, "/callback?code=abc&state=S1") }
        #expect(got.all.count == 1, "a second request is not a second answer")
    }

    @Test func silentConnectionsDoNotHoldUpTheRightRequest() async throws {
        let (listener, port, got) = try await start()
        defer { listener.stop() }
        // Three sockets that connect and say nothing, as a browser's spare connections do.
        let silent = (0..<3).map { _ in
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }
        for connection in silent { connection.start(queue: .global()) }
        defer { for connection in silent { connection.cancel() } }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        let (status, _) = try await get(port, "/callback?code=abc&state=S1")
        #expect(status == 200)
        // A request held up behind the silent sockets waits for their 5 s idle drop (one after another: 15 s).
        // Answering before that is the fact; the margin to 5 s is for a starved CI runner.
        #expect(started.duration(to: .now) < .seconds(4.5))
        await waitForCallback(got)
        #expect(got.all.count == 1)
    }

    @Test func stopClosesTheSocket() async throws {
        let (listener, port, _) = try await start()
        listener.stop()
        try? await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) { _ = try await self.get(port, "/callback?code=a&state=S1") }
    }

    @Test func aPortInUseIsReportedAsBusy() async throws {
        let (first, port, _) = try await start()
        defer { first.stop() }
        let second = OAuthLoopbackListener(state: "S2", port: port) { _ in }
        await #expect(throws: OAuthLoopbackError.portBusy) { try await second.start() }
        second.stop()
    }

    @Test func aRequestOverTheLimitIsRefusedAndTheListenerGoesOn() async throws {
        let (listener, port, got) = try await start()
        defer { listener.stop() }
        let long = String(repeating: "a", count: OAuthLoopback.maxRequestBytes + 100)
        let (status, _) = try await get(port, "/callback?state=S1&code=\(long)")
        #expect(status == 431)
        #expect(got.all.isEmpty)
        #expect(try await get(port, "/callback?code=abc&state=S1").0 == 200)
    }

    @Test func itListensOnLoopbackOnly() async throws {
        let (listener, port, _) = try await start()
        defer { listener.stop() }
        // Reached by 127.0.0.1 (the other tests); an address of this Mac on the network gets nothing.
        var address: String?
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let item = pointer.pointee
                guard item.ifa_addr?.pointee.sa_family == UInt8(AF_INET), (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
                else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    item.ifa_addr, socklen_t(item.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST)
                address = String(cString: host)
                break
            }
        }
        guard let address else { return }  // no network interface in this environment
        var request = URLRequest(url: URL(string: "http://\(address):\(port)/callback?code=a&state=S1")!)
        request.timeoutInterval = 2
        await #expect(throws: (any Error).self) { _ = try await self.session().data(for: request) }
    }
}
