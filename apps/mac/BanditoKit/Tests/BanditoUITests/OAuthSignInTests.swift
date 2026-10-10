import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// A server that answers the sign-in calls from a script and records what it was asked.
@MainActor
private final class FakeServer: OAuthServer {
    let oauthServerID: UUID
    var beginAnswer: Result<OAuthBegun, Error> = .success(
        OAuthBegun(authorizeUrl: "https://mcp.example/authorize?x=1", state: "state-1"))
    var completeAnswer: Result<OAuthCompleted, Error> = .success(OAuthCompleted(id: "i1", name: "linear", created: true))
    var begun: [OAuthBeginTarget] = []
    var completed: [(state: String, code: String, iss: String?)] = []
    var cancelled: [String] = []
    /// Waits inside `oauthBegin` until released, to test a cancel that comes while the server is answering.
    var gate: CheckedContinuation<Void, Never>?
    var holdBegin = false

    init(id: UUID = UUID()) { oauthServerID = id }

    func oauthBegin(_ target: OAuthBeginTarget) async throws -> OAuthBegun {
        begun.append(target)
        if holdBegin { await withCheckedContinuation { gate = $0 } }
        return try beginAnswer.get()
    }

    func oauthComplete(state: String, code: String, iss: String?) async throws -> OAuthCompleted {
        completed.append((state, code, iss))
        return try completeAnswer.get()
    }

    func oauthCancel(state: String) async { cancelled.append(state) }
}

private struct Boom: Error {}

/// Time and the opened addresses, held outside the model so the model's closures can read them.
private final class Box: @unchecked Sendable {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var opened: [URL] = []
}

@MainActor
private final class Rig {
    let defaults: UserDefaults
    let suite: String
    private let box = Box()
    let oauth: OAuthSignIn

    init() {
        let suite = "oauth-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let box = self.box
        self.suite = suite
        self.defaults = defaults
        oauth = OAuthSignIn(defaults: defaults, now: { box.clock }, opener: { box.opened.append($0) })
    }

    var openedURLs: [URL] { box.opened }
    func advance(_ seconds: TimeInterval) { box.clock = box.clock.addingTimeInterval(seconds) }

    /// Another model on the same stored state: the app after a restart.
    func restarted() -> OAuthSignIn {
        let box = self.box
        return OAuthSignIn(defaults: defaults, now: { box.clock }, opener: { box.opened.append($0) })
    }

    func tearDown() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
@Suite struct OAuthSignInTests {
    private let linear = NewIntegration(name: "linear", kind: .http, url: "https://mcp.linear.app/mcp")

    private func callback(_ state: String, code: String = "code-1", extra: String = "") -> URL {
        URL(string: "bandito://oauth/callback?code=\(code)&state=\(state)\(extra)")!
    }

    @Test func beginOpensTheBrowserAndWaits() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        #expect(rig.oauth.phase == .waiting(name: "Linear"))
        #expect(rig.openedURLs.map(\.absoluteString) == ["https://mcp.example/authorize?x=1"])
        #expect(server.begun == [.draft(linear)])
    }

    @Test func theCallbackGoesToTheServerThatBeganAndEndsConnected() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        let handled = await rig.oauth.handle(callback("state-1", extra: "&iss=https%3A%2F%2Fmcp.example")) {
            $0 == server.oauthServerID ? server : nil
        }
        #expect(handled == server.oauthServerID)
        #expect(server.completed.count == 1)
        #expect(server.completed.first?.state == "state-1")
        #expect(server.completed.first?.code == "code-1")
        #expect(server.completed.first?.iss == "https://mcp.example")
        #expect(rig.oauth.phase == .connected(name: "linear", integrationID: "i1"))
    }

    @Test func aCallbackForTheServerThatBeganDoesNotReachAnotherOne() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let first = FakeServer()
        let second = FakeServer()
        await rig.oauth.begin(server: first, target: .draft(linear), name: "Linear")
        _ = await rig.oauth.handle(callback("state-1")) { id in [first, second].first { $0.oauthServerID == id } }
        #expect(first.completed.count == 1)
        #expect(second.completed.isEmpty)
    }

    @Test func aStateTheAppDoesNotKnowIsNotPassedOn() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        _ = await rig.oauth.handle(callback("someone-elses-state")) { _ in server }
        #expect(server.completed.isEmpty)
        guard case .failed(_, let message, let canRetry) = rig.oauth.phase else {
            Issue.record("expected a failure, got \(rig.oauth.phase)")
            return
        }
        #expect(!message.text.isEmpty)
        #expect(!canRetry)
    }

    @Test func theSameCallbackTwiceCompletesOnce() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        _ = await rig.oauth.handle(callback("state-1")) { _ in server }
        _ = await rig.oauth.handle(callback("state-1")) { _ in server }
        #expect(server.completed.count == 1)
        #expect(rig.oauth.phase == .connected(name: "linear", integrationID: "i1"))
    }

    @Test func aCallbackAfterTenMinutesIsRefused() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        rig.advance(OAuthSignIn.lifetime + 1)
        _ = await rig.oauth.handle(callback("state-1")) { _ in server }
        #expect(server.completed.isEmpty)
        if case .failed = rig.oauth.phase {} else { Issue.record("expected a failure, got \(rig.oauth.phase)") }
    }

    @Test func aDeniedCallbackTellsTheServerAndOffersTryAgain() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        let denied = URL(string: "bandito://oauth/callback?error=access_denied&state=state-1")!
        _ = await rig.oauth.handle(denied) { _ in server }
        #expect(server.completed.isEmpty)
        #expect(server.cancelled == ["state-1"])
        guard case .failed(_, _, let canRetry) = rig.oauth.phase else {
            Issue.record("expected a failure, got \(rig.oauth.phase)")
            return
        }
        #expect(canRetry)
        // Try again starts the same sign-in anew.
        server.beginAnswer = .success(OAuthBegun(authorizeUrl: "https://mcp.example/authorize?x=2", state: "state-2"))
        await rig.oauth.retry()
        #expect(rig.oauth.phase == .waiting(name: "Linear"))
        #expect(server.begun.count == 2)
    }

    @Test func aServerThatRefusesTheCodeEndsInAFailureWithItsText() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        server.completeAnswer = .failure(Boom())
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        _ = await rig.oauth.handle(callback("state-1")) { _ in server }
        guard case .failed(_, let message, _) = rig.oauth.phase else {
            Issue.record("expected a failure, got \(rig.oauth.phase)")
            return
        }
        #expect(!message.text.isEmpty)
        #expect(message.technical != nil)
    }

    @Test func cancelDropsTheStateOnTheServerAndForgetsIt() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        await rig.oauth.dismiss()
        #expect(rig.oauth.phase == .idle)
        #expect(server.cancelled == ["state-1"])
        // A late browser answer finds nothing waiting.
        _ = await rig.oauth.handle(callback("state-1")) { _ in server }
        #expect(server.completed.isEmpty)
    }

    @Test func aCancelWhileTheServerIsStillAnsweringDropsTheLateState() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        server.holdBegin = true
        let start = Task { await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear") }
        while server.gate == nil { await Task.yield() }
        await rig.oauth.dismiss()
        #expect(rig.oauth.phase == .idle)
        server.gate?.resume()
        await start.value
        #expect(rig.oauth.phase == .idle)
        #expect(rig.openedURLs.isEmpty, "the browser must not open for a sign-in that was given up")
        #expect(server.cancelled == ["state-1"])
    }

    @Test func aBeginThatFailsShowsTheFailureAndOpensNothing() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        server.beginAnswer = .failure(Boom())
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        if case .failed = rig.oauth.phase {} else { Issue.record("expected a failure, got \(rig.oauth.phase)") }
        #expect(rig.openedURLs.isEmpty)
    }

    @Test func onlyAWebAddressIsOpened() async {
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "bandito://oauth/callback", "http://evil.example/a", "notaurl", ""] {
            let rig = Rig()
            defer { rig.tearDown() }
            let server = FakeServer()
            server.beginAnswer = .success(OAuthBegun(authorizeUrl: bad, state: "state-bad"))
            await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
            #expect(rig.openedURLs.isEmpty, "\(bad)")
            #expect(server.cancelled == ["state-bad"], "\(bad)")
            if case .failed = rig.oauth.phase {} else { Issue.record("\(bad): got \(rig.oauth.phase)") }
        }
        #expect(OAuthSignIn.browserURL("https://mcp.example/authorize") != nil)
        #expect(OAuthSignIn.browserURL("http://localhost:7000/authorize") != nil)
    }

    @Test func aRestartedAppStillKnowsWhichServerBeganTheSignIn() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        let again = rig.restarted()
        _ = await again.handle(callback("state-1")) { id in id == server.oauthServerID ? server : nil }
        #expect(server.completed.count == 1)
        #expect(again.phase == .connected(name: "linear", integrationID: "i1"))
    }

    @Test func aNewSignInDropsTheOneThatWasWaiting() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let server = FakeServer()
        await rig.oauth.begin(server: server, target: .draft(linear), name: "Linear")
        server.beginAnswer = .success(OAuthBegun(authorizeUrl: "https://mcp.example/authorize?x=2", state: "state-2"))
        await rig.oauth.begin(server: server, target: .existing(id: "i9"), name: "Notion")
        #expect(server.cancelled == ["state-1"])
        _ = await rig.oauth.handle(callback("state-1")) { _ in server }
        #expect(server.completed.isEmpty, "the first state no longer completes anything")
        #expect(rig.oauth.isActive)
    }

    // MARK: the status words

    @Test func aRefusedSignInReadsAsNeedingLogin() {
        let row = Integration(id: "i1", name: "linear", kind: .http, url: "https://x", auth: .oauth)
        #expect(IntegrationStatus.of(row, test: nil, connection: .needsLogin) == .needsLogin)
        #expect(IntegrationStatus.of(row, test: nil, connection: .notConnected) == .needsLogin)
        #expect(
            IntegrationStatus.of(row, test: IntegrationTest(ok: false, error: "x", needsLogin: true), connection: .connected)
                == .needsLogin)
        #expect(IntegrationStatus.of(row, test: nil, connection: .connected) == .unchecked)
        #expect(IntegrationStatus.of(row, test: IntegrationTest(ok: true, tools: ["a"]), connection: .connected) == .connected(tools: 1))
        // A key-based integration never reads as needing a sign-in, and a switched-off one stays off.
        let plain = Integration(id: "i2", name: "fetch", kind: .http, url: "https://x")
        #expect(IntegrationStatus.of(plain, test: nil, connection: .notConnected) == .unchecked)
        var off = row
        off.enabled = false
        #expect(IntegrationStatus.of(off, test: nil, connection: .needsLogin) == .disabled)
    }

    @Test func aBrowserSignInHasOneStepOnTheServicePage() {
        let oauth = IntegrationCatalogEntry(
            id: "linear", name: "Linear", descriptionEn: "", descriptionRu: "", kind: .http, url: "https://mcp.linear.app/mcp",
            docsUrl: "", icon: "", auth: .oauth)
        #expect(MarketLogic.steps(for: oauth) == [.signIn])
    }
}
