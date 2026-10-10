import Foundation
import Testing

@testable import BanditoKit

@Suite struct RuntimeModelsTests {
    func decodeLists(_ json: String) throws -> [RuntimeModelList] {
        try RPCClient.decoder.decode([RuntimeModelList].self, from: Data(json.utf8))
    }

    @Test func decodesTheModelsAnswer() throws {
        let lists = try decodeLists(
            #"""
            [{"runtime":"claude","models":[{"id":"opus","name":"Opus 5.5","description":"For complex work and everyday tasks","is_default":true,"efforts":["low","medium","high","xhigh","max"]},{"id":"haiku","name":"Haiku 5.5","is_default":false,"efforts":[]}],"error":null,"fetched_at":1765000000000}]
            """#)
        let claude = try #require(lists.first)
        #expect(claude.runtime == .claude)
        #expect(claude.error == nil)
        #expect(claude.fetchedAt == 1_765_000_000_000)
        #expect(claude.models.count == 2)
        #expect(claude.defaultModel?.id == "opus")
        #expect(claude.models[0].description == "For complex work and everyday tasks")
        #expect(claude.models[0].supportedEfforts == [.low, .medium, .high, .xhigh, .max])
        #expect(claude.models[1].description == nil)
        #expect(claude.models[1].supportedEfforts.isEmpty)
    }

    @Test func decodesAnErrorWithoutModels() throws {
        let lists = try decodeLists(
            #"[{"runtime":"codex","models":[],"error":"not_installed","fetched_at":1}]"#)
        let codex = try #require(lists.first)
        #expect(codex.runtime == .codex)
        #expect(codex.models.isEmpty)
        #expect(codex.error == "not_installed")
        #expect(codex.defaultModel == nil)
    }

    @Test func decodesAFailureReason() throws {
        let lists = try decodeLists(
            #"[{"runtime":"grok","models":[],"error":"timed out after 20 s","fetched_at":1}]"#)
        #expect(lists.first?.error == "timed out after 20 s")
    }

    @Test func unknownEffortNamesAreIgnored() {
        let model = RuntimeModel(id: "m", name: "M", efforts: ["high", "turbo", "low"])
        #expect(model.supportedEfforts == [.low, .high])
    }

    @Test func modelWithoutNameUsesItsId() throws {
        let lists = try decodeLists(
            #"[{"runtime":"claude","models":[{"id":"sonnet"}],"fetched_at":1}]"#)
        let model = try #require(lists.first?.models.first)
        #expect(model.name == "sonnet")
        #expect(model.isDefault == false)
        #expect(model.efforts.isEmpty)
    }

    @Test func nearestKeepsALevelTheModelOffers() {
        #expect(Effort.medium.nearest(in: [.low, .medium, .high]) == .medium)
    }

    @Test func nearestPicksTheClosestOfferedLevel() {
        #expect(Effort.max.nearest(in: [.low, .medium, .high]) == .high)
        #expect(Effort.low.nearest(in: [.high, .max]) == .high)
    }

    @Test func nearestGoesDownOnATie() {
        // xhigh is one step from high and from max: the lower level wins.
        #expect(Effort.xhigh.nearest(in: [.high, .max]) == .high)
    }

    @Test func nearestOfNothingIsNil() {
        #expect(Effort.medium.nearest(in: []) == nil)
    }

    @Test func gateWaitsForTheDaemonInfo() {
        #expect(RuntimeModelsGate.decide(hasInfo: false, supportsModels: false) == .wait)
        #expect(RuntimeModelsGate.decide(hasInfo: false, supportsModels: true) == .wait)
    }

    @Test func gateSkipsADaemonWithoutTheFeature() {
        #expect(RuntimeModelsGate.decide(hasInfo: true, supportsModels: false) == .unsupported)
    }

    @Test func gateAsksADaemonWithTheFeature() {
        #expect(RuntimeModelsGate.decide(hasInfo: true, supportsModels: true) == .ask)
    }

    func daemonInfo(features: [String]?) -> DaemonInfo {
        DaemonInfo(
            version: "0.9.0", hostname: "vps-1", os: "linux", arch: "x86_64", startedAt: 0, lastSeq: 0,
            features: features)
    }

    @MainActor @Test func statusWaitsWhileTheInfoIsUnknown() async throws {
        let server = ServerModel(config: ServerConfig(name: "vps-1", endpoint: .defaultLocal))
        try await server.refreshRuntimeModels()
        #expect(server.runtimeModelsStatus == .unknown)
        #expect(server.runtimeModels.isEmpty)
    }

    @MainActor @Test func oldDaemonIsUnsupportedNotFailed() async throws {
        let server = ServerModel(config: ServerConfig(name: "vps-1", endpoint: .defaultLocal))
        server.info = daemonInfo(features: ["agents", "files"])
        try await server.refreshRuntimeModels()
        #expect(server.runtimeModelsStatus == .unsupported)
    }

    @MainActor @Test func failedRequestIsFailedWithItsReason() async {
        let server = ServerModel(config: ServerConfig(name: "vps-1", endpoint: .defaultLocal))
        server.info = daemonInfo(features: ["runtime_models"])
        // No connection: the request cannot be sent, and the status keeps the reason.
        await #expect(throws: RPCError.self) {
            try await server.refreshRuntimeModels()
        }
        guard case .failed(let reason) = server.runtimeModelsStatus else {
            Issue.record("a request that could not be sent is a failure, not an unsupported daemon")
            return
        }
        #expect(reason.contains("not connected"))
    }
}
