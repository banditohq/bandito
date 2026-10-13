import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// A server that answers the code sign-in calls from a script and records what it was asked.
@MainActor
private final class FakeServer: DeviceServer {
    let deviceServerID = UUID()
    var beginAnswers: [Result<DeviceBegun, Error>] = []
    /// What each status read answers, in order; the last one repeats.
    var statuses: [Result<DeviceFlowState, Error>] = [.success(.pending)]
    var begun: [DeviceBeginTarget] = []
    var reads = 0
    var cancelled: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdBegin = false

    func deviceBegin(_ target: DeviceBeginTarget) async throws -> DeviceBegun {
        begun.append(target)
        if holdBegin { await withCheckedContinuation { gate = $0 } }
        return try (beginAnswers.isEmpty ? Self.defaultBegun(begun.count) : beginAnswers.removeFirst()).get()
    }

    func deviceStatus(flowId: String) async throws -> DeviceStatus {
        let answer = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        reads += 1
        return DeviceStatus(flowId: flowId, state: try answer.get())
    }

    func deviceCancel(flowId: String) async { cancelled.append(flowId) }

    static func defaultBegun(_ n: Int) -> Result<DeviceBegun, Error> {
        .success(
            DeviceBegun(
                flowId: "flow-\(n)", userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device",
                expiresAt: 1_760_000_900_000))
    }
}

private struct Boom: Error {}

/// What the model put on the pasteboard and opened.
private final class Box: @unchecked Sendable {
    var copied: [String] = []
    var opened: [URL] = []
}

@MainActor
private func makeModel(_ box: Box) -> DeviceSignIn {
    DeviceSignIn(
        pollEvery: .milliseconds(1),
        copyToPasteboard: { box.copied.append($0) },
        openURL: { box.opened.append($0) },
        sleep: { try await Task.sleep(for: $0) })
}

/// Waits until `check` holds, up to two seconds.
@MainActor
private func until(_ check: () -> Bool) async {
    for _ in 0..<6000 where !check() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
@Suite struct DeviceSignInTests {
    private let github = NewIntegration(name: "github", kind: .http, url: "https://api.githubcopilot.com/mcp/")

    private func isWaiting(_ phase: DeviceSignIn.Phase) -> Bool {
        if case .waiting = phase { return true }
        return false
    }

    @Test func beginShowsTheCodeAndTheDeadlineAndTouchesNothingByItself() async {
        let box = Box()
        let model = makeModel(box)
        let server = FakeServer()
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        guard case .waiting(let name, let code, let page, let expires) = model.phase else {
            Issue.record("not waiting: \(model.phase)")
            return
        }
        #expect(name == "GitHub" && code == "WDJB-MJHT" && page.address == "github.com/login/device")
        #expect(expires == Date(timeIntervalSince1970: 1_760_000_900))
        #expect(server.begun == [.draft(github)])
        #expect(box.copied.isEmpty && box.opened.isEmpty && !model.copied)
        await model.dismiss()
    }

    @Test func copyPutsTheCodeOnThePasteboardAndOpenCopiesItAndOpensThePage() async {
        let box = Box()
        let model = makeModel(box)
        await model.begin(server: FakeServer(), target: .draft(github), name: "GitHub")
        model.copyCode()
        #expect(box.copied == ["WDJB-MJHT"] && box.opened.isEmpty && model.copied)
        model.openPage()
        #expect(box.copied == ["WDJB-MJHT", "WDJB-MJHT"])
        #expect(box.opened.map(\.absoluteString) == ["https://github.com/login/device"])
        await model.dismiss()
        // Nothing to copy once the sheet is gone.
        model.copyCode()
        model.openPage()
        #expect(box.copied.count == 2 && box.opened.count == 1)
    }

    @Test func aConfirmationEndsInConnectedWithTheIntegration() async {
        let server = FakeServer()
        server.statuses = [.success(.pending), .success(.pending), .success(.done(integrationID: "i1", name: "github", created: true))]
        let model = makeModel(Box())
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        await until { model.phase == .connected(name: "GitHub", integrationID: "i1") }
        #expect(model.phase == .connected(name: "GitHub", integrationID: "i1"))
        #expect(server.reads == 3)
        // The poll stopped; closing a finished sign-in does not cancel anything at the server.
        await model.dismiss()
        #expect(model.phase == .idle && server.cancelled.isEmpty)
    }

    @Test func eachReasonHasItsOwnWordsAndTryAgainStartsANewCode() async {
        for (reason, expectRetry) in [(DeviceFailure.expired, true), (.denied, true), (.refused, true), (.network, true), (.store, true), (.other, true)] {
            let server = FakeServer()
            server.statuses = [.success(.failed(reason, detail: "raw detail"))]
            let model = makeModel(Box())
            await model.begin(server: server, target: .draft(github), name: "GitHub")
            await until { !isWaiting(model.phase) }
            guard case .failed(let name, let message, let canRetry) = model.phase else {
                Issue.record("\(reason): \(model.phase)")
                continue
            }
            #expect(name == "GitHub" && canRetry == expectRetry && !message.text.isEmpty)
            if reason == .expired || reason == .denied { #expect(message.technical == nil) }
            if reason == .refused || reason == .network { #expect(message.technical == "raw detail") }
            // Try again: a new flow, a new code.
            server.statuses = [.success(.pending)]
            await model.retry()
            #expect(isWaiting(model.phase) && server.begun.count == 2)
            await model.dismiss()
            #expect(server.cancelled == ["flow-2"])
        }
    }

    @Test func aFailedStartIsAFailureWithRetry() async {
        let server = FakeServer()
        server.beginAnswers = [.failure(Boom())]
        let model = makeModel(Box())
        await model.begin(server: server, target: .existing(id: "i1"), name: "GitHub")
        guard case .failed(_, let message, let canRetry) = model.phase else {
            Issue.record("\(model.phase)")
            return
        }
        #expect(canRetry && !message.text.isEmpty)
        await model.retry()
        #expect(isWaiting(model.phase) && server.begun == [.existing(id: "i1"), .existing(id: "i1")])
        await model.dismiss()
    }

    @Test func aPageThatIsNotWebIsRefusedAndTheFlowIsGivenUp() async {
        let server = FakeServer()
        server.beginAnswers = [.success(DeviceBegun(flowId: "f9", userCode: "AB-CD", verificationUri: "file:///etc/passwd", expiresAt: 1))]
        let model = makeModel(Box())
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        if case .failed = model.phase {} else { Issue.record("\(model.phase)") }
        #expect(server.cancelled == ["f9"])
    }

    @Test func closingTheSheetGivesTheFlowUpAtTheServerAndStopsThePoll() async {
        let server = FakeServer()
        let model = makeModel(Box())
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        await until { server.reads >= 2 }
        await model.dismiss()
        #expect(model.phase == .idle && server.cancelled == ["flow-1"])
        let reads = server.reads
        try? await Task.sleep(for: .milliseconds(40))
        #expect(server.reads == reads)
    }

    @Test func aCancelWhileTheServerIsAnsweringDropsTheLateCode() async {
        let server = FakeServer()
        server.holdBegin = true
        let model = makeModel(Box())
        let started = Task { await model.begin(server: server, target: .draft(github), name: "GitHub") }
        await until { server.gate != nil }
        #expect(model.phase == .starting(name: "GitHub"))
        await model.dismiss()
        server.gate?.resume()
        await started.value
        #expect(model.phase == .idle && server.cancelled == ["flow-1"])
    }

    @Test func aNewBeginGivesTheEarlierFlowUp() async {
        let server = FakeServer()
        let model = makeModel(Box())
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        #expect(server.cancelled == ["flow-1"] && isWaiting(model.phase))
        await model.dismiss()
        #expect(server.cancelled == ["flow-1", "flow-2"])
    }

    @Test func aFlowThatEndedAtTheServerClosesTheSheet() async {
        let server = FakeServer()
        server.statuses = [.success(.cancelled)]
        let model = makeModel(Box())
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        await until { model.phase == .idle }
        #expect(model.phase == .idle && !model.isActive)
    }

    @Test func statusReadsThatKeepFailingEndTheSignInButOneFailureDoesNot() async {
        let server = FakeServer()
        server.statuses = [.failure(Boom()), .success(.pending), .success(.done(integrationID: "i1", name: "g", created: false))]
        let model = makeModel(Box())
        await model.begin(server: server, target: .draft(github), name: "GitHub")
        await until { model.phase == .connected(name: "GitHub", integrationID: "i1") }
        #expect(model.phase == .connected(name: "GitHub", integrationID: "i1"))

        let broken = FakeServer()
        broken.statuses = [.failure(Boom())]
        let other = makeModel(Box())
        await other.begin(server: broken, target: .draft(github), name: "GitHub")
        await until { !isWaiting(other.phase) }
        if case .failed(_, _, let canRetry) = other.phase { #expect(canRetry) } else { Issue.record("\(other.phase)") }
        #expect(broken.reads == DeviceSignIn.maxReadFailures)
    }

    @Test func theMarketStepsForACodeSignInHaveNoKeyAndNoFields() throws {
        let entry = try RPCClient.decoder.decode(
            IntegrationCatalogEntry.self,
            from: Data(
                ##"{"id":"github","name":"GitHub","description_en":"E","description_ru":"Р","kind":"http","url":"https://api.githubcopilot.com/mcp/","docs_url":"https://d","icon":"github","auth":"device"}"##.utf8))
        #expect(MarketLogic.steps(for: entry) == [.signInCode])
    }
}
