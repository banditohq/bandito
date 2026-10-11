import Foundation
import Testing

@testable import BanditoKit

@Suite struct TelemetryServiceTests {
    private static let client = ClientInfo(app: "0.1.10", build: 1240, os: "15.3", arch: "arm64")
    private static let base = URL(string: "https://bandito.dev/api/v1")!

    private func facts() -> PulseFacts {
        PulseFacts(
            client: Self.client, lang: "ru", region: "RU", servers: [], agentCount: 0, runtimes: [], telegram: false)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "telemetry-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func makeTelemetry(
        defaults: UserDefaults, http: HTTPClient, signedIn: String? = nil
    ) -> Telemetry {
        Telemetry(
            defaults: defaults, http: http, baseURL: Self.base,
            sessionToken: { signedIn })
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let emptyPulse = ScriptedReply(#"{"ok":true,"announcements":[]}"#)

    @Test func installIDIsUUIDv4AndKeptAcrossLaunches() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:])).installID
        let again = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:])).installID
        #expect(first == again)
        let uuid = UUID(uuidString: first)
        #expect(uuid?.uuidString.lowercased() == first)
        #expect(first.split(separator: "-")[2].first == "4")
    }

    @Test func countsAccumulatePerDayAndSurviveARestart() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        let telemetry = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        telemetry.count(.screen(.team), now: now)
        telemetry.count(.screen(.team), now: now)
        telemetry.count(.skillInstall, now: now.addingTimeInterval(86_400))

        let restarted = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        #expect(restarted.pendingCounters(day: "2026-06-11") == ["screen.team.open": 2])
        #expect(restarted.pendingCounters(day: "2026-06-12") == ["skill.install": 1])
    }

    @Test func disabledStatsCountNothingAndEraseWhatWasStored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        let telemetry = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        telemetry.count(.dictationUse, now: now)
        #expect(!telemetry.pendingCounters(day: "2026-06-11").isEmpty)

        telemetry.statsEnabled = false

        #expect(telemetry.pendingCounters(day: "2026-06-11").isEmpty)
        telemetry.count(.dictationUse, now: now)
        #expect(telemetry.pendingCounters(day: "2026-06-11").isEmpty)
    }

    @Test func disabledStatsSendNoPulseAndNoAnnouncementEvent() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = ScriptedHTTP(["POST /telemetry/pulse": [Self.emptyPulse]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)
        telemetry.statsEnabled = false

        let announcements = await telemetry.sendPulse(facts: facts(), now: Date())
        await telemetry.sendAnnouncementEvent(id: "a1", event: .shown)

        #expect(announcements == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func pulseClearsOnlyTheCountersThatWereSent() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        let http = ScriptedHTTP(["POST /telemetry/pulse": [Self.emptyPulse]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)
        telemetry.count(.screen(.files), now: now)
        telemetry.count(.screen(.files), now: now)

        let sent = await telemetry.sendPulse(facts: facts(), now: now)
        #expect(sent != nil)

        let body = try jsonBody(try #require(http.requests.last))
        #expect(body["day"] as? String == "2026-06-11")
        #expect((body["counters"] as? [String: Int]) == ["screen.files.open": 2])
        #expect(telemetry.pendingCounters(day: "2026-06-11").isEmpty)
    }

    @Test func failedPulseKeepsCountersForTheNextLaunch() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        // No route: the network fails.
        let telemetry = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        telemetry.count(.importRun, now: now)

        let sent = await telemetry.sendPulse(facts: facts(), now: now)

        #expect(sent == nil)
        #expect(telemetry.pendingCounters(day: "2026-06-11") == ["import.run": 1])
    }

    @Test func pulseSendsPendingPreviousDaysAndKeepsAnnouncements() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        let reply = ScriptedReply(
            #"{"ok":true,"announcements":[{"id":"n-1","title":"Hi","body":"Body","level":"banner","expires_at":"2099-01-01T00:00:00Z"}]}"#)
        // Days go in order, so yesterday's pulse is the first request and today's the last: today's reply wins.
        let http = ScriptedHTTP(["POST /telemetry/pulse": [Self.emptyPulse, reply]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)
        telemetry.count(.formReply, now: now.addingTimeInterval(-86_400))

        let announcements = await telemetry.sendPulse(facts: facts(), now: now)

        #expect(http.requests.count == 2)
        #expect(announcements?.map(\.id) == ["n-1"])
        #expect(telemetry.pendingCounters(day: "2026-06-10").isEmpty)
    }

    @Test func pulseCarriesBearerOnlyWhenSignedIn() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let anonymous = ScriptedHTTP(["POST /telemetry/pulse": [Self.emptyPulse]])
        _ = await makeTelemetry(defaults: defaults, http: anonymous).sendPulse(facts: facts(), now: Date())
        #expect(anonymous.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)

        let signed = ScriptedHTTP(["POST /telemetry/pulse": [Self.emptyPulse]])
        _ = await makeTelemetry(defaults: defaults, http: signed, signedIn: "tok-1").sendPulse(
            facts: facts(), now: Date())
        #expect(signed.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    }

    @Test func forgetDeletesOnServerThenRotatesTheInstallID() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = ScriptedHTTP(["POST /telemetry/forget": [ScriptedReply(#"{"ok":true}"#)]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)
        let old = telemetry.installID
        telemetry.count(.shareInstall)

        try await telemetry.forget()

        let body = try jsonBody(try #require(http.requests.last))
        #expect(body["install_id"] as? String == old)
        #expect(telemetry.installID != old)
        #expect(UUID(uuidString: telemetry.installID) != nil)
        #expect(telemetry.pendingCounters(day: TelemetryPulse.day(for: Date())).isEmpty)
    }

    @Test func failedForgetKeepsTheInstallIDForARetry() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let telemetry = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        let old = telemetry.installID

        await #expect(throws: TelemetryError.self) {
            try await telemetry.forget()
        }
        #expect(telemetry.installID == old)
    }

    @Test func crashIsNotSentWithoutConsent() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = ScriptedHTTP(["POST /telemetry/crash": [ScriptedReply(#"{"ok":true}"#)]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)
        #expect(telemetry.crashReports == nil)

        let sent = await telemetry.sendCrash(CrashSummary(kind: "EXC_BAD_ACCESS", frames: ["Bandito`f"]), client: Self.client)

        #expect(!sent)
        #expect(http.requests.isEmpty)
    }

    @Test func crashWithConsentSendsKindAndFramesWithoutPaths() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = ScriptedHTTP(["POST /telemetry/crash": [ScriptedReply(#"{"ok":true}"#)]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)
        telemetry.setCrashReports(true)

        let sent = await telemetry.sendCrash(
            CrashSummary(kind: "EXC_BAD_ACCESS", frames: ["Bandito`StoreModel.save()"]), client: Self.client)

        #expect(sent)
        let body = try jsonBody(try #require(http.requests.last))
        #expect(Set(body.keys) == ["install_id", "app", "build", "os", "arch", "kind", "frames"])
        #expect(body["kind"] as? String == "EXC_BAD_ACCESS")
        #expect(body["frames"] as? [String] == ["Bandito`StoreModel.save()"])
    }

    @Test func announcementEventPostsIDAndEvent() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = ScriptedHTTP(["POST /announcements/event": [ScriptedReply(#"{"ok":true}"#)]])
        let telemetry = makeTelemetry(defaults: defaults, http: http)

        await telemetry.sendAnnouncementEvent(id: "n-7", event: .clicked)

        let body = try jsonBody(try #require(http.requests.last))
        #expect(Set(body.keys) == ["install_id", "id", "event"])
        #expect(body["id"] as? String == "n-7")
        #expect(body["event"] as? String == "clicked")
    }

    @Test func shownAnnouncementsAreRememberedAcrossLaunches() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let telemetry = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        #expect(!telemetry.isShown("n-1"))
        telemetry.markShown("n-1")
        #expect(makeTelemetry(defaults: defaults, http: ScriptedHTTP([:])).isShown("n-1"))
    }

    @Test func noticeIsShownOnlyUntilSeen() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let telemetry = makeTelemetry(defaults: defaults, http: ScriptedHTTP([:]))
        #expect(!telemetry.hasSeenNotice)
        telemetry.markNoticeSeen()
        #expect(makeTelemetry(defaults: defaults, http: ScriptedHTTP([:])).hasSeenNotice)
    }
}
