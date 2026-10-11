import Foundation
import Testing

@testable import BanditoKit

/// The sharing calls of `AccountClient` on scripted HTTP: the routes, the sign-in rule, the answers and their failures.
@Suite struct ShareClientTests {
    private static let shareID = "k3HqT9vZ2Lm8pXcR4wBn7e"

    private func botPayload() -> JSONValue {
        .object([
            "schema": .number(1),
            "name": .string("Release notes"),
            "system_prompt": .string("Write the notes."),
            "files": .object(["scripts/my_tool.py": .string("print(1)")]),
        ])
    }

    private func draft(visibility: ShareVisibility = .everyone) -> ShareDraft {
        ShareDraft(
            kind: .bot, visibility: visibility, lang: "en", title: "Release notes", summary: "Notes",
            payload: botPayload())
    }

    @Test func createShareSendsTheDraftWithTheSessionAndReturnsTheLink() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let http = ScriptedHTTP([
            "POST /shares": [ScriptedReply(#"{"ok":true,"id":"\#(Self.shareID)","url":"https://bandito.dev/s/\#(Self.shareID)"}"#, status: 201)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        let created = try await client.createShare(draft())

        #expect(created.id == Self.shareID)
        #expect(created.url == "https://bandito.dev/s/\(Self.shareID)")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_1")
        let body = try jsonBody(request)
        #expect(body["kind"] as? String == "bot")
        #expect(body["visibility"] as? String == "public")
        // The payload goes out with its keys as the daemon wrote them: no snake_case rewrite of `system_prompt`
        // or of a file name.
        let payload = try #require(body["payload"] as? [String: Any])
        #expect(payload["system_prompt"] as? String == "Write the notes.")
        let files = try #require(payload["files"] as? [String: Any])
        #expect(files["scripts/my_tool.py"] as? String == "print(1)")
    }

    @Test func createShareWithoutASessionSendsNothing() async throws {
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http)

        await #expect(throws: ShareFailure.unauthorized) {
            _ = try await client.createShare(draft())
        }
        #expect(http.requests.isEmpty)
    }

    @Test func aSecretRefusalNamesItsField() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let http = ScriptedHTTP([
            "POST /shares": [ScriptedReply(#"{"ok":false,"error":"looks_like_secret","field":"payload.system_prompt"}"#, status: 422)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        await #expect(throws: ShareFailure.looksLikeSecret(field: "payload.system_prompt")) {
            _ = try await client.createShare(draft())
        }
    }

    @Test func limitsMapToTheirOwnFailures() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let rate = ScriptedHTTP(["POST /shares": [ScriptedReply(#"{"ok":false,"error":"rate"}"#, status: 429)]])
        let tooMany = ScriptedHTTP(["POST /shares": [ScriptedReply(#"{"ok":false,"error":"too_many"}"#, status: 409)]])

        await #expect(throws: ShareFailure.rate) {
            _ = try await makeClient(http: rate, sessions: sessions).createShare(draft())
        }
        await #expect(throws: ShareFailure.tooMany) {
            _ = try await makeClient(http: tooMany, sessions: sessions).createShare(draft())
        }
    }

    @Test func anUnknownErrorCodeKeepsItsCodeAndStatus() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let http = ScriptedHTTP(["POST /shares": [ScriptedReply(#"{"ok":false,"error":"new_thing"}"#, status: 400)]])

        await #expect(throws: ShareFailure.api(code: "new_thing", status: 400)) {
            _ = try await makeClient(http: http, sessions: sessions).createShare(draft())
        }
    }

    @Test func getShareNeedsNoSessionAndKeepsThePayload() async throws {
        let http = ScriptedHTTP([
            "GET /shares/\(Self.shareID)": [
                ScriptedReply(
                    #"{"ok":true,"share":{"id":"\#(Self.shareID)","kind":"skill","visibility":"link","title":"pdf","summary":"Read PDFs","lang":"en","author":{"login":null,"name":"Ann"},"version":3,"installs":2,"created_at":1700000000000,"updated_at":1700000100000,"payload":{"schema":1,"name":"pdf","executable":["scripts/run_me.sh"],"files":{"scripts/run_me.sh":"echo"}}}}"#)
            ]
        ])
        let client = try makeClient(http: http)

        let item = try await client.getShare(id: Self.shareID)

        #expect(item.kind == .skill)
        #expect(item.visibility == .link)
        #expect(item.version == 3)
        #expect(item.author.login == nil)
        #expect(item.author.name == "Ann")
        #expect(item.createdAt == 1_700_000_000_000)
        #expect(item.payload["executable"] == .array([.string("scripts/run_me.sh")]))
        #expect(item.payload["files"]?["scripts/run_me.sh"] == .string("echo"))
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aHiddenOrRemovedShareIsItsOwnFailure() async throws {
        let hidden = ScriptedHTTP([
            "GET /shares/\(Self.shareID)": [ScriptedReply(#"{"ok":false,"error":"hidden"}"#, status: 410)]
        ])
        let gone = ScriptedHTTP([
            "GET /shares/\(Self.shareID)": [ScriptedReply(#"{"ok":false,"error":"not_found"}"#, status: 404)]
        ])

        await #expect(throws: ShareFailure.hidden) {
            _ = try await makeClient(http: hidden).getShare(id: Self.shareID)
        }
        await #expect(throws: ShareFailure.notFound) {
            _ = try await makeClient(http: gone).getShare(id: Self.shareID)
        }
    }

    @Test func aMalformedIdIsRefusedBeforeAnyRequest() async throws {
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http)

        await #expect(throws: ShareFailure.invalid) {
            _ = try await client.getShare(id: "../etc/passwd")
        }
        await #expect(throws: ShareFailure.invalid) {
            _ = try await client.getShare(id: "short")
        }
        #expect(http.requests.isEmpty)
    }

    @Test func myListsTheOwnSharesWithoutPayloads() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let http = ScriptedHTTP([
            "GET /shares/mine": [
                ScriptedReply(
                    #"{"ok":true,"shares":[{"id":"\#(Self.shareID)","kind":"bot","visibility":"public","title":"Release notes","summary":"","lang":"en","version":2,"installs":14,"hidden":true,"created_at":1,"updated_at":2}]}"#)
            ]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        let shares = try await client.myShares()

        #expect(shares.count == 1)
        #expect(shares[0].hidden)
        #expect(shares[0].installs == 14)
        #expect(shares[0].updatedAt == 2)
    }

    @Test func updateSendsOnlyTheFieldsThatChange() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let http = ScriptedHTTP([
            "PATCH /shares/\(Self.shareID)": [ScriptedReply(#"{"ok":true,"version":3}"#)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        try await client.updateShare(id: Self.shareID, ShareUpdate(visibility: .link))

        let body = try jsonBody(try #require(http.requests.first))
        #expect(body.keys.sorted() == ["visibility"])
        #expect(body["visibility"] as? String == "link")
    }

    @Test func deleteAndReportAndInstallCountUseTheirOwnRoutes() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_1")
        let http = ScriptedHTTP([
            "DELETE /shares/\(Self.shareID)": [ScriptedReply(#"{"ok":true}"#)],
            "POST /shares/\(Self.shareID)/report": [ScriptedReply(#"{"ok":true}"#)],
            "POST /shares/\(Self.shareID)/installed": [ScriptedReply(#"{"ok":true}"#)],
        ])
        let client = try makeClient(http: http, sessions: sessions)

        try await client.deleteShare(id: Self.shareID)
        try await client.reportShare(id: Self.shareID, reason: .malicious, note: "")
        try await client.markInstalled(id: Self.shareID)

        let keys = http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(keys.contains("DELETE /api/v1/shares/\(Self.shareID)"))
        #expect(keys.contains("POST /api/v1/shares/\(Self.shareID)/report"))
        #expect(keys.contains("POST /api/v1/shares/\(Self.shareID)/installed"))
        // The install count and a report go without a session.
        let installed = try #require(http.requests.last)
        #expect(installed.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
