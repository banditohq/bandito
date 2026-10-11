import Foundation
import Testing

@testable import BanditoKit

@Suite struct TelemetryEventTests {
    @Test func namesAreTheContractWhitelist() {
        let events: [TelemetryEvent] = [
            .screen(.team), .screen(.market), .screen(.settings), .screen(.terminals), .screen(.files),
            .screen(.browser),
            .agentCreate(.plain), .agentCreate(.template), .agentCreate(.bundle), .agentCreate(.shared),
            .integration(CatalogCounterID("github")!, ok: true), .integration(CatalogCounterID("github")!, ok: false),
            .skillInstall, .sharePublish, .shareInstall, .dictationUse, .approval(.allow), .approval(.deny),
            .telegramLink, .importRun, .formReply, .turnComplete,
            .turnFail(.error), .turnFail(.interrupted), .turnFail(.other),
        ]
        #expect(
            events.map(\.name) == [
                "screen.team.open", "screen.market.open", "screen.settings.open", "screen.terminals.open",
                "screen.files.open", "screen.browser.open",
                "agent.create", "agent.create.template", "agent.create.bundle", "agent.create.shared",
                "integration.connect.github.ok", "integration.connect.github.fail",
                "skill.install", "share.publish", "share.install", "dictation.use", "approval.allow",
                "approval.deny", "telegram.link", "import.run", "form.reply", "turn.complete",
                "turn.fail.error", "turn.fail.interrupted", "turn.fail.other",
            ])
    }

    @Test func everyEmittedNameIsAllowed() {
        #expect(TelemetryEvent.isAllowedName("screen.team.open"))
        #expect(TelemetryEvent.isAllowedName("agent.create.shared"))
        #expect(TelemetryEvent.isAllowedName("turn.complete"))
        #expect(TelemetryEvent.isAllowedName("turn.fail.interrupted"))
        #expect(!TelemetryEvent.isAllowedName("turn.fail.crash"))
        #expect(TelemetryEvent.isAllowedName("integration.connect.google-calendar.fail"))
        #expect(!TelemetryEvent.isAllowedName("turn.fail.timeout"))
        #expect(!TelemetryEvent.isAllowedName("screen.team.open.extra"))
        #expect(!TelemetryEvent.isAllowedName("integration.connect.Bad Name.ok"))
        #expect(!TelemetryEvent.isAllowedName("integration.connect.github.maybe"))
        #expect(!TelemetryEvent.isAllowedName("message.text"))
    }

    @Test func catalogIDIsLowercaseSlugOnly() {
        #expect(CatalogCounterID("google-calendar") != nil)
        #expect(CatalogCounterID("notion_2") != nil)
        #expect(CatalogCounterID("") == nil)
        #expect(CatalogCounterID("Github") == nil)
        #expect(CatalogCounterID("a/b") == nil)
        #expect(CatalogCounterID("with space") == nil)
        #expect(CatalogCounterID(String(repeating: "a", count: 40)) != nil)
        #expect(CatalogCounterID(String(repeating: "a", count: 41)) == nil)
    }
}

@Suite struct TelemetryPulseTests {
    static let install = "7d3c5a52-1f0e-4b8a-9c2d-3e4f5a6b7c8d"

    private func facts(
        servers: [PulseServer] = [PulseServer(os: "macos", arch: "arm64", daemon: "0.1.9")],
        agents: Int = 3, runtimes: [String] = ["claude", "codex"]
    ) -> PulseFacts {
        PulseFacts(
            client: ClientInfo(app: "0.1.10", build: 1240, os: "15.3", arch: "arm64"),
            lang: "ru", region: "RU", servers: servers, agentCount: agents, runtimes: runtimes, telegram: true)
    }

    private func object(_ body: PulseBody) throws -> [String: Any] {
        let data = try TelemetryWire.encode(body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func bodyHasOnlyTheContractFields() throws {
        let body = TelemetryPulse.body(
            installID: Self.install, facts: facts(), counters: ["screen.team.open": 2], day: "2026-10-11")
        let json = try object(body)
        #expect(
            Set(json.keys) == [
                "install_id", "app", "build", "os", "arch", "lang", "region", "servers", "agents_bucket",
                "runtimes", "telegram", "counters", "day",
            ])
        #expect(json["install_id"] as? String == Self.install)
        #expect(json["app"] as? String == "0.1.10")
        #expect(json["build"] as? Int == 1240)
        #expect(json["region"] as? String == "RU")
        #expect(json["agents_bucket"] as? String == "2-5")
        #expect(json["telegram"] as? Bool == true)
        #expect(json["day"] as? String == "2026-10-11")
        #expect((json["counters"] as? [String: Int]) == ["screen.team.open": 2])
    }

    @Test func serversCarryOnlyOSArchAndDaemonVersion() throws {
        let body = TelemetryPulse.body(installID: Self.install, facts: facts(), counters: [:], day: "2026-10-11")
        let servers = try #require(try object(body)["servers"] as? [[String: Any]])
        #expect(servers.count == 1)
        #expect(Set(servers[0].keys) == ["os", "arch", "daemon"])
        #expect(servers[0]["daemon"] as? String == "0.1.9")
    }

    @Test func bodyNeverCarriesAddressesOrNames() throws {
        let body = TelemetryPulse.body(installID: Self.install, facts: facts(), counters: [:], day: "2026-10-11")
        let text = try #require(String(data: try TelemetryWire.encode(body), encoding: .utf8))
        for forbidden in ["host", "name", "address", "://", "@", "ip", "path", "token"] {
            #expect(!text.lowercased().contains(forbidden), "pulse must not contain \(forbidden)")
        }
    }

    @Test func agentsBucketsFollowThePlan() {
        #expect(AgentsBucket.bucket(for: 0) == .zero)
        #expect(AgentsBucket.bucket(for: 1) == .one)
        #expect(AgentsBucket.bucket(for: 2) == .twoToFive)
        #expect(AgentsBucket.bucket(for: 5) == .twoToFive)
        #expect(AgentsBucket.bucket(for: 6) == .sixToTwenty)
        #expect(AgentsBucket.bucket(for: 20) == .sixToTwenty)
        #expect(AgentsBucket.bucket(for: 21) == .moreThanTwenty)
        #expect(AgentsBucket.moreThanTwenty.rawValue == "20+")
    }

    @Test func unknownCounterNamesAreDropped() throws {
        let body = TelemetryPulse.body(
            installID: Self.install,
            facts: facts(),
            counters: [
                "screen.team.open": 1, "integration.connect.github.ok": 2, "pwned": 3,
                "integration.connect.Bad Name.ok": 4, "message.text": 5,
            ],
            day: "2026-10-11")
        #expect(body.counters == ["screen.team.open": 1, "integration.connect.github.ok": 2])
    }

    @Test func countersAndServersAreCapped() {
        var many: [String: Int] = [:]
        for index in 0..<150 {
            many["integration.connect.svc\(index).ok"] = 500_000
        }
        let servers = Array(repeating: PulseServer(os: "linux", arch: "x86_64", daemon: "0.1.9"), count: 12)
        let body = TelemetryPulse.body(
            installID: Self.install, facts: facts(servers: servers), counters: many, day: "2026-10-11")
        #expect(body.servers.count == 10)
        #expect(body.counters.count == 100)
        #expect(body.counters.values.allSatisfy { $0 == 100_000 })
    }

    @Test func runtimesAreSortedAndUnique() {
        let body = TelemetryPulse.body(
            installID: Self.install, facts: facts(runtimes: ["codex", "claude", "codex"]),
            counters: [:], day: "2026-10-11")
        #expect(body.runtimes == ["claude", "codex"])
    }

    @Test func dayIsUTCDate() {
        let date = Date(timeIntervalSince1970: 1_781_136_000)  // 2026-06-11T00:00:00Z
        #expect(TelemetryPulse.day(for: date) == "2026-06-11")
    }
}
