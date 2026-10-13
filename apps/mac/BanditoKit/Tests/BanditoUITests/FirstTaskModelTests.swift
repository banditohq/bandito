import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// A server whose thread is its own list: `send` can fail before anything is made, or after the message is in the thread
/// (the answer lost); the thread can be unreadable (the connection is down).
@MainActor
private final class FakeTaskServer: TaskSending {
    var agents = [Agent(id: "a", name: "Forge", runtime: .claude, cwd: "/p")]
    var serverTexts: [String] = []
    var sends = 0
    var failsBeforeSending = 0
    var losesAnswer = false
    var readFailures = 0
    private var local = AgentThread()

    struct Boom: Error {}

    func send(_ text: String, to agentId: String) async throws {
        sends += 1
        if failsBeforeSending > 0 {
            failsBeforeSending -= 1
            throw Boom()
        }
        serverTexts.append(text)
        if losesAnswer { throw Boom() }
        // A local echo, as the app shows its own message at once: it must decide nothing.
    }

    func loadHistory(_ agentId: String) async throws {
        if readFailures > 0 {
            readFailures -= 1
            throw Boom()
        }
        var thread = AgentThread()
        for (index, text) in serverTexts.enumerated() {
            thread.items.append(.user(id: "m\(index)", text: text, source: .user, from: nil, ts: 0))
        }
        local = thread
    }

    func thread(for agentId: String) -> AgentThread { local }
}

@MainActor
@Suite struct FirstTaskModelTests {
    private func model(_ server: FakeTaskServer) -> FirstTaskModel {
        let model = FirstTaskModel(server: server, agentID: "a", teamID: nil)
        model.setText("Look around")
        return model
    }

    @Test func aSendThatWorksSendsOnce() async {
        let server = FakeTaskServer()
        let task = model(server)
        #expect(await task.send())
        #expect(server.sends == 1)
    }

    @Test func aLostAnswerIsNotSentTwiceBecauseTheServersThreadHasIt() async {
        let server = FakeTaskServer()
        server.losesAnswer = true
        let task = model(server)
        #expect(await task.send() == false)
        #expect(task.failure?.canRetry == true)
        server.losesAnswer = false
        #expect(await task.send())
        #expect(server.sends == 1)
        #expect(server.serverTexts == ["Look around"])
    }

    @Test func aSendThatFailedBeforeAnythingWasMadeIsSentAgain() async {
        let server = FakeTaskServer()
        server.failsBeforeSending = 1
        let task = model(server)
        #expect(await task.send() == false)
        #expect(await task.send())
        #expect(server.sends == 2)
        #expect(server.serverTexts == ["Look around"])
    }

    @Test func aTextThatWasInTheThreadBeforeIsNotTakenForTheRetry() async {
        let server = FakeTaskServer()
        server.serverTexts = ["Look around"]
        server.failsBeforeSending = 1
        let task = model(server)
        #expect(await task.send() == false)
        // The old message is the baseline: it is not "the agent got it".
        #expect(await task.send())
        #expect(server.sends == 2)
        #expect(server.serverTexts.count == 2)
    }

    @Test func withTheThreadUnreadableNothingIsSent() async {
        let server = FakeTaskServer()
        server.readFailures = 1
        let task = model(server)
        #expect(await task.send() == false)
        #expect(server.sends == 0)
        #expect(task.failure?.canRetry == true)
        #expect(await task.send())
        #expect(server.sends == 1)
    }

    @Test func aRetryWithTheThreadUnreadableWaitsInsteadOfGuessing() async {
        let server = FakeTaskServer()
        server.losesAnswer = true
        let task = model(server)
        #expect(await task.send() == false)
        server.readFailures = 1
        #expect(await task.send() == false)
        #expect(server.sends == 1)
        #expect(await task.send())
        #expect(server.sends == 1)
    }
}
