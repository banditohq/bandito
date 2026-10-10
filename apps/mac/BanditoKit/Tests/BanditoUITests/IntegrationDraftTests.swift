import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The integration sheet: names, the checks before a save, what a save sends, and the words for a check result.
@Suite struct IntegrationDraftTests {
    private func catalog(_ id: String, headers: [IntegrationHeaderKey] = []) -> IntegrationCatalogEntry {
        IntegrationCatalogEntry(
            id: id, name: id, descriptionEn: "d", descriptionRu: "д", kind: headers.isEmpty ? .stdio : .http,
            command: "npx", args: ["-y", "pkg"], url: headers.isEmpty ? nil : "https://x.test/mcp", headersKeys: headers,
            docsUrl: "https://docs.test", icon: "x")
    }

    private func bearer(_ key: String = "Authorization") -> IntegrationHeaderKey {
        IntegrationHeaderKey(key: key, labelEn: "Token", labelRu: "Токен", secret: true, valueTemplate: "Bearer {secret}")
    }

    @Test func namesAreLowercaseOfTheDaemonsSet() {
        #expect(IntegrationDraft.isValidName("github"))
        #expect(IntegrationDraft.isValidName("my-tool_2"))
        #expect(!IntegrationDraft.isValidName(""))
        #expect(!IntegrationDraft.isValidName("GitHub"))
        #expect(!IntegrationDraft.isValidName("has space"))
        #expect(!IntegrationDraft.isValidName("bandito"))
        #expect(IntegrationDraft.isValidName(String(repeating: "a", count: 40)))
        #expect(!IntegrationDraft.isValidName(String(repeating: "a", count: 41)))
    }

    @Test func secretNamesComeFromTheIntegrationAndTheKey() {
        #expect(IntegrationDraft.secretName(integration: "github", key: "Authorization") == "GITHUB_AUTHORIZATION")
        #expect(IntegrationDraft.secretName(integration: "composio", key: "x-api-key") == "COMPOSIO_X_API_KEY")
        #expect(IntegrationDraft.secretName(integration: "1st", key: "a") == "_1ST_A")
        #expect(IntegrationDraft.secretName(integration: "x", key: String(repeating: "k", count: 90)).count == 64)
        #expect(SecretRules.isValidName(IntegrationDraft.secretName(integration: "gh", key: "Authorization")))
    }

    @Test func catalogStartsWithItsNameAndItsSecretHeader() {
        let draft = IntegrationDraft.fromCatalog(catalog("github", headers: [bearer()]))
        #expect(draft.name == "github")
        #expect(draft.kind == .http)
        #expect(draft.url == "https://x.test/mcp")
        #expect(draft.headers.count == 1)
        #expect(draft.headers[0].isSecret)
        #expect(draft.headers[0].template == "Bearer {secret}")
        #expect(draft.problem(existingNames: []) == .secretMissing("Authorization"))
    }

    @Test func aStdioCatalogEntryNeedsNoSecretAndKeepsItsArguments() {
        let draft = IntegrationDraft.fromCatalog(catalog("fetch"))
        #expect(draft.argsText == "-y pkg")
        #expect(draft.args == ["-y", "pkg"])
        #expect(draft.problem(existingNames: []) == nil)
    }

    @Test func saveRunsTheChecksInOrder() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        #expect(draft.problem(existingNames: []) == .nameEmpty)
        draft.name = "Bad Name"
        #expect(draft.problem(existingNames: []) == .nameInvalid)
        draft.name = "fetch"
        #expect(draft.problem(existingNames: ["fetch"]) == .nameTaken)
        #expect(draft.problem(existingNames: []) == .commandEmpty)
        draft.command = "uvx"
        #expect(draft.problem(existingNames: []) == nil)
    }

    @Test func httpNeedsHttpsOrLocalhost() {
        #expect(IntegrationDraft.isURL("https://mcp.linear.app/mcp"))
        #expect(IntegrationDraft.isURL("http://localhost:8787/mcp"))
        #expect(!IntegrationDraft.isURL("http://example.com/mcp"))
        #expect(!IntegrationDraft.isURL("https://"))
        #expect(!IntegrationDraft.isURL(""))

        var draft = IntegrationDraft.custom(kind: .http)
        draft.name = "linear"
        draft.url = "http://example.com"
        #expect(draft.problem(existingNames: []) == .urlInvalid)
    }

    @Test func keysAreLettersDigitsAndSomePunctuation() {
        #expect(IntegrationDraft.isValidKey("x-api-key"))
        #expect(IntegrationDraft.isValidKey("A.B_c"))
        #expect(!IntegrationDraft.isValidKey("with space"))
        #expect(!IntegrationDraft.isValidKey(""))

        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.name = "tool"
        draft.command = "run"
        draft.env = [IntegrationPair(key: "BAD KEY", value: "1")]
        #expect(draft.problem(existingNames: []) == .keyInvalid("BAD KEY"))
    }

    @Test func buildSendsTheSecretAndTheReferenceOnCreate() {
        var draft = IntegrationDraft.fromCatalog(catalog("github", headers: [bearer()]))
        draft.headers[0].value = "  ghp_token  "
        #expect(draft.problem(existingNames: []) == nil)

        let save = draft.build()
        #expect(save.patch == nil)
        #expect(save.secrets == [IntegrationSecretWrite(name: "GITHUB_AUTHORIZATION", value: "ghp_token")])
        #expect(save.create?.name == "github")
        #expect(save.create?.kind == .http)
        #expect(save.create?.url == "https://x.test/mcp")
        #expect(save.create?.command == nil)
        #expect(save.create?.headers == ["Authorization": "Bearer secret:GITHUB_AUTHORIZATION"])
        #expect(save.create?.enabled == true)
    }

    @Test func buildKeepsLiteralsAndLeavesOutTheEmptyOnes() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.name = "fs"
        draft.command = " npx "
        draft.argsText = "  -y   @x/fs  /data "
        draft.env = [
            IntegrationPair(key: "ROOT", value: "/data"),
            IntegrationPair(key: "  ", value: "dropped"),
        ]
        let save = draft.build()
        #expect(save.secrets.isEmpty)
        #expect(save.create?.command == "npx")
        #expect(save.create?.args == ["-y", "@x/fs", "/data"])
        #expect(save.create?.env == ["ROOT": "/data"])
        #expect(save.create?.headers.isEmpty == true)
        #expect(save.create?.url == nil)
    }

    @Test func aStoredSecretKeepsItsReferenceUntilRetyped() {
        let row = Integration(
            id: "i1", name: "linear", kind: .http, url: "https://mcp.linear.app/mcp",
            headers: ["Authorization": "secret:LINEAR_KEY"])
        var draft = IntegrationDraft.editing(row)
        #expect(draft.headers.first?.isSecret == true)
        #expect(draft.headers.first?.storedSecret == "LINEAR_KEY")
        #expect(draft.problem(existingNames: ["linear"]) == nil, "its own name is not taken")

        let untouched = draft.build()
        #expect(untouched.secrets.isEmpty)
        #expect(untouched.create == nil)
        #expect(untouched.patch?.headers == ["Authorization": "secret:LINEAR_KEY"])

        draft.headers[0].value = "new-token"
        let retyped = draft.build()
        #expect(retyped.secrets == [IntegrationSecretWrite(name: "LINEAR_KEY", value: "new-token")])
        #expect(retyped.patch?.headers == ["Authorization": "secret:LINEAR_KEY"])
    }

    @Test func editingSendsTheDefinitionAndClearsTheOtherTransport() throws {
        let row = Integration(id: "i2", name: "tool", kind: .stdio, command: "uvx", args: ["a"], url: nil)
        var draft = IntegrationDraft.editing(row)
        draft.command = "uvx2"
        let patch = try #require(draft.build().patch)
        let object = try #require(try JSONSerialization.jsonObject(
            with: RPCClient.encoder.encode(patch)) as? [String: Any])
        #expect(object["command"] as? String == "uvx2")
        #expect(object["url"] is NSNull)
        #expect(object["args"] as? [String] == ["a"])
        #expect(object["name"] as? String == "tool")
        #expect(object["enabled"] == nil)
        #expect(object["id"] == nil)
    }

    @Test func aSavedDraftKeepsTheTypedSecretUntilItIsWritten() {
        var draft = IntegrationDraft.fromCatalog(catalog("github", headers: [bearer()]))
        draft.headers[0].value = "ghp_token"
        draft.assignSecretNames(taken: [])
        draft.markSaved(id: "i7")
        #expect(draft.editingID == "i7")
        #expect(draft.originalName == "github")
        #expect(draft.headers[0].value == "ghp_token", "kept so a failed write can be retried")
        #expect(draft.build().secrets == [IntegrationSecretWrite(name: "GITHUB_AUTHORIZATION", value: "ghp_token")])

        draft.markSecretsWritten()
        #expect(draft.headers[0].value.isEmpty)
        #expect(draft.headers[0].storedSecret == "GITHUB_AUTHORIZATION")
        let again = draft.build()
        #expect(again.secrets.isEmpty)
        #expect(again.patch?.headers == ["Authorization": "Bearer secret:GITHUB_AUTHORIZATION"])
    }

    @Test func secretWritesGoToNoAgent() {
        var draft = IntegrationDraft.fromCatalog(catalog("github", headers: [bearer()]))
        draft.headers[0].value = "t"
        let writes = draft.build().secrets
        #expect(writes.count == 1)
        #expect(writes.allSatisfy { $0.agents.isEmpty })
    }

    @Test func aTakenSecretNameGetsASuffixAndAnOwnNameStays() {
        var draft = IntegrationDraft.fromCatalog(catalog("github", headers: [bearer()]))
        draft.headers[0].value = "t"
        draft.assignSecretNames(taken: ["GITHUB_AUTHORIZATION"])
        #expect(draft.headers[0].storedSecret == "GITHUB_AUTHORIZATION_2")
        #expect(draft.build().secrets == [IntegrationSecretWrite(name: "GITHUB_AUTHORIZATION_2", value: "t")])
        #expect(draft.build().create?.headers == ["Authorization": "Bearer secret:GITHUB_AUTHORIZATION_2"])

        // A row that already holds a secret keeps it, even when the name is taken by someone else.
        let row = Integration(id: "i3", name: "linear", kind: .http, url: "https://mcp.linear.app/mcp",
                              headers: ["Authorization": "secret:LINEAR_KEY"])
        var kept = IntegrationDraft.editing(row)
        kept.headers[0].value = "new"
        kept.assignSecretNames(taken: ["LINEAR_KEY"])
        #expect(kept.headers[0].storedSecret == "LINEAR_KEY")
    }

    @Test func twoNewSecretsOfOneSaveNeverShareAName() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.name = "a-b"
        draft.command = "run"
        draft.env = [
            IntegrationPair(key: "x-k", value: "1", isSecret: true),
            IntegrationPair(key: "x_k", value: "2", isSecret: true),
        ]
        draft.assignSecretNames(taken: [])
        let names = draft.env.compactMap(\.storedSecret)
        #expect(names == ["A_B_X_K", "A_B_X_K_2"])
        #expect(Set(names).count == 2)
    }

    @Test func aSuffixedNameStaysWithinSixtyFourCharacters() {
        let base = String(repeating: "A", count: 64)
        let name = IntegrationDraft.freeName(base: base, used: [base])
        #expect(name.count == 64)
        #expect(name.hasSuffix("_2"))
    }

    @Test func aStoredSecretSwitchedOffWithoutValueIsRefused() {
        let row = Integration(id: "i4", name: "linear", kind: .http, url: "https://mcp.linear.app/mcp",
                              headers: ["Authorization": "secret:LINEAR_KEY"])
        var draft = IntegrationDraft.editing(row)
        draft.headers[0].isSecret = false
        #expect(draft.problem(existingNames: ["linear"]) == .valueMissing("Authorization"))
        draft.headers[0].value = "typed literal"
        #expect(draft.problem(existingNames: ["linear"]) == nil)
    }

    @Test func aRenameIntoAnotherIntegrationsNameIsTaken() {
        let row = Integration(id: "i1", name: "alpha", kind: .stdio, command: "x")
        var draft = IntegrationDraft.editing(row)
        draft.name = "beta"
        #expect(draft.problem(existingNames: ["alpha", "beta"]) == .nameTaken)
        #expect(draft.problem(existingNames: ["alpha"]) == nil)
    }

    @Test func statusFollowsTheRowAndTheLastCheck() {
        let on = Integration(id: "i", name: "a", kind: .stdio, command: "x")
        var off = on
        off.enabled = false
        #expect(IntegrationStatus.of(off, test: IntegrationTest(ok: true, tools: ["t"])) == .disabled)
        #expect(IntegrationStatus.of(on, test: nil) == .unchecked)
        #expect(IntegrationStatus.of(on, test: IntegrationTest(ok: true, tools: ["a", "b"])) == .connected(tools: 2))
        #expect(IntegrationStatus.of(on, test: IntegrationTest(ok: false, error: "spawn npx: ENOENT"))
            == .failed(.missingProgram))
    }

    @Test func failuresAreWordedByKind() {
        #expect(IntegrationFailure.classify("sh: npx: command not found") == .missingProgram)
        #expect(IntegrationFailure.classify("HTTP 401 Unauthorized") == .rejected)
        #expect(IntegrationFailure.classify("curl: (7) Failed to connect to host") == .unreachable)
        #expect(IntegrationFailure.classify("the server timed out") == .timeout)
        #expect(IntegrationFailure.classify("something odd") == .other)
        #expect(IntegrationFailure.classify(nil) == .other)
    }
}
