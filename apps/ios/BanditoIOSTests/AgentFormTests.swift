import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The glue of the agent forms on iPhone: the runtime a new agent starts on, the one-agent request built from the
/// fields, and when the form can be sent. The rules themselves (model, folder, rights, ready teams) are BanditoKit's and
/// are tested there.
@Suite struct AgentFormTests {
    @Test func theFirstInstalledRuntimeIsTheDefault() throws {
        #expect(AgentForms.defaultRuntime(try runtimes(installed: [])) == nil)
        #expect(AgentForms.defaultRuntime(try runtimes(installed: [.grok])) == .grok)
        #expect(AgentForms.defaultRuntime(try runtimes(installed: [.grok, .codex, .claude])) == .claude)
    }

    @Test func theApprovalChoicesAreInTheMacsOrder() {
        #expect(AgentForms.approvalOrder == [.always, .risky, .never])
    }

    @Test func oneAgentNeedsANameARuntimeAndAFolderAndNoRequestUnderWay() {
        #expect(AgentForms.canCreateOne(name: "Ledger", runtime: .claude, folder: "/a/Ledger", busy: false))
        #expect(!AgentForms.canCreateOne(name: "  ", runtime: .claude, folder: "/a/Ledger", busy: false))
        #expect(!AgentForms.canCreateOne(name: "Ledger", runtime: nil, folder: "/a/Ledger", busy: false))
        #expect(!AgentForms.canCreateOne(name: "Ledger", runtime: .claude, folder: "", busy: false))
        #expect(!AgentForms.canCreateOne(name: "Ledger", runtime: .claude, folder: "/a/Ledger", busy: true))
    }

    @Test func theCreateBodyCarriesTheFieldsTheFormHas() throws {
        let agent = AgentForms.newAgent(
            name: " Ledger ", role: "Bookkeeper", runtime: .claude, model: "haiku", folder: "/a/Ledger",
            approval: .always, effort: .high, permissions: [.terminal, .files])
        let body = try wire(agent)
        #expect(body["name"] as? String == "Ledger")
        #expect(body["role"] as? String == "Bookkeeper")
        #expect(body["runtime"] as? String == "claude")
        #expect(body["model"] as? String == "haiku")
        #expect(body["cwd"] as? String == "/a/Ledger")
        #expect(body["approval_mode"] as? String == "always")
        #expect(body["effort"] as? String == "high")
        #expect(body["capabilities"] as? [String] == ["terminal", "files"])
    }

    @Test func aDefaultModelAndEffortAreLeftOutOfTheCreateBody() throws {
        let agent = AgentForms.newAgent(
            name: "Ledger", role: "", runtime: .codex, model: "  ", folder: "/a/Ledger", approval: .risky,
            effort: nil, permissions: [])
        let body = try wire(agent)
        #expect(body["model"] == nil)
        #expect(body["effort"] == nil)
        #expect(body["capabilities"] as? [String] == [])
    }

    // MARK: fixtures

    /// The runtimes of `runtimes.status`, with the given kinds installed.
    private func runtimes(installed: [RuntimeKind]) throws -> [RuntimeStatus] {
        let entries = [RuntimeKind.claude, .codex, .grok].map { kind -> [String: Any] in
            [
                "kind": kind.rawValue, "installed": installed.contains(kind), "logged_in": NSNull(),
                "version": NSNull(), "detail": NSNull(), "supported_capabilities": [String](),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        return try JSONDecoder.wire.decode([RuntimeStatus].self, from: data)
    }

    /// The request body as the RPC client sends it.
    private func wire<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder.wire.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension JSONEncoder {
    /// The encoder of an RPC request: snake_case keys, as `RPC.swift` sends them.
    static var wire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

extension JSONDecoder {
    /// The decoder of an RPC answer: snake_case keys, as `RPC.swift` reads them.
    static var wire: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
