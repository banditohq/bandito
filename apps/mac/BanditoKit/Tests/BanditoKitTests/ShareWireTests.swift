import Foundation
import Testing

@testable import BanditoKit

/// The wire of the sharing features: ids, the platform's error codes, the daemon's refusals, and the answers of the
/// daemon's bot creation, which are read with `RPCClient.decoder` like every other daemon answer.
@Suite struct ShareWireTests {
    @Test func aShareIDIsExactlyTwentyTwoBase62Characters() {
        #expect(ShareID.isValid("k3HqT9vZ2Lm8pXcR4wBn7e"))
        #expect(!ShareID.isValid("k3HqT9vZ2Lm8pXcR4wBn7"))
        #expect(!ShareID.isValid("k3HqT9vZ2Lm8pXcR4wBn7e!"))
        #expect(!ShareID.isValid("k3HqT9vZ2Lm8pXcR4wBn-e"))
        #expect(!ShareID.isValid("../../../../etc/passw"))
        #expect(!ShareID.isValid(""))
    }

    @Test func platformErrorCodesMapToTheirCases() {
        #expect(ShareFailure.from(code: "looks_like_secret", status: 422, field: "summary") == .looksLikeSecret(field: "summary"))
        #expect(ShareFailure.from(code: "looks_like_secret", status: 422, field: nil) == .looksLikeSecret(field: ""))
        #expect(ShareFailure.from(code: "rate", status: 429, field: nil) == .rate)
        #expect(ShareFailure.from(code: "too_many", status: 409, field: nil) == .tooMany)
        #expect(ShareFailure.from(code: "hidden", status: 410, field: nil) == .hidden)
        #expect(ShareFailure.from(code: "not_found", status: 404, field: nil) == .notFound)
        #expect(ShareFailure.from(code: "unauthorized", status: 401, field: nil) == .unauthorized)
        #expect(ShareFailure.from(code: "invalid", status: 400, field: nil) == .invalid)
        #expect(ShareFailure.from(code: "later", status: 500, field: nil) == .api(code: "later", status: 500))
    }

    @Test func aBareStatusDecidesWhenThereIsNoCode() {
        #expect(ShareFailure.from(status: 401) == .unauthorized)
        #expect(ShareFailure.from(status: 404) == .notFound)
        #expect(ShareFailure.from(status: 410) == .hidden)
        #expect(ShareFailure.from(status: 429) == .rate)
        #expect(ShareFailure.from(status: 503) == .api(code: "http_503", status: 503))
    }

    @Test func aDaemonFolderRefusalNamesItsReason() {
        let refusal = RPCError(
            code: RPCError.commandsError, message: "exists", data: .object(["reason": .string("exists_not_ours")]))
        #expect(SharedInstallFailure(refusal) == .reason("exists_not_ours"))

        let noReason = RPCError(code: RPCError.commandsError, message: "io")
        #expect(SharedInstallFailure(noReason) == .reason("io"))
    }

    @Test func aPayloadRefusalNamesTheField() {
        let invalid = RPCError(code: RPCError.invalidParams, message: "invalid: system_prompt")
        #expect(SharedInstallFailure(invalid) == .invalid(field: "system_prompt"))

        let other = RPCError(code: RPCError.invalidParams, message: "no agent x")
        #expect(SharedInstallFailure(other) == .other("no agent x"))
    }

    @Test func aShareSummaryReadsItsSnakeCaseDates() throws {
        let json = """
            {"id":"k3HqT9vZ2Lm8pXcR4wBn7e","kind":"skill","visibility":"public","title":"pdf","summary":"",\
            "version":1,"installs":0,"created_at":10,"updated_at":20}
            """
        let summary = try JSONDecoder().decode(ShareSummary.self, from: Data(json.utf8))
        #expect(summary.kind == .skill)
        #expect(summary.visibility == .everyone)
        #expect(summary.createdAt == 10)
        #expect(summary.updatedAt == 20)
        #expect(summary.hidden == false)
        #expect(summary.lang == nil)
    }

    @Test func aBotCreationFromTheDaemonReadsItsSnakeCaseLists() throws {
        let json = """
            {"agent":null,"schedule_ids":["s1","s2"],"unknown_services":["nope"],"missing_services":["github"],\
            "errors":[{"step":"schedule","message":"bad cron"}],"starter":"Hi!"}
            """
        let created = try RPCClient.decoder.decode(SharedBotCreation.self, from: Data(json.utf8))
        #expect(created.agent == nil)
        #expect(created.scheduleIds == ["s1", "s2"])
        #expect(created.unknownServices == ["nope"])
        #expect(created.missingServices == ["github"])
        #expect(created.errors == [SharedStepError(step: "schedule", message: "bad cron")])
        #expect(created.starter == "Hi!")
    }

    @Test func aDraftKeepsThePayloadKeysAndNamesTheEnumValues() throws {
        let draft = ShareDraft(
            kind: .bot, visibility: .everyone, lang: "ru", title: "t", summary: "s",
            payload: .object(["system_prompt": .string("p")]))
        let data = try JSONEncoder().encode(draft)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["visibility"] as? String == "public")
        #expect(object["kind"] as? String == "bot")
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["system_prompt"] as? String == "p")
    }

    @Test func reportReasonsAreTheFiveOfThePlatform() {
        #expect(ShareReportReason.allCases.map(\.rawValue) == ["spam", "malicious", "secrets", "offensive", "other"])
    }
}
