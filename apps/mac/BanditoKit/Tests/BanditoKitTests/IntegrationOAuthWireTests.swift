import Foundation
import Testing

@testable import BanditoKit

/// The wire of the browser sign-in (`integrations.oauth_*`) and the address the browser sends the owner back to.
@Suite struct IntegrationOAuthWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func anIntegrationReadsHowItSignsInAndAnOlderDaemonMeansNone() throws {
        let oauth = try decode(
            Integration.self,
            #"{"id":"i1","name":"linear","kind":"http","url":"https://mcp.linear.app/mcp","enabled":true,"created_at":1,"auth":"oauth"}"#)
        #expect(oauth.auth == .oauth)
        let old = try decode(Integration.self, #"{"id":"i2","name":"fetch","kind":"stdio","command":"uvx"}"#)
        #expect(old.auth == .none)
        // A value a newer daemon might add does not break the list.
        let odd = try decode(Integration.self, #"{"id":"i3","name":"x","kind":"http","url":"https://x","auth":"saml"}"#)
        #expect(odd.auth == .none)
    }

    @Test func aCatalogEntryKnowsWhetherItSignsInInTheBrowser() throws {
        let entry = try decode(
            IntegrationCatalogEntry.self,
            ##"{"id":"linear","name":"Linear","description_en":"E","description_ru":"Р","kind":"http","url":"https://mcp.linear.app/mcp","docs_url":"https://d","icon":"linear","auth":"oauth"}"##)
        #expect(entry.usesOAuth)
        let plain = try decode(
            IntegrationCatalogEntry.self,
            ##"{"id":"fetch","name":"Fetch","description_en":"E","description_ru":"Р","kind":"stdio","command":"uvx","docs_url":"https://d","icon":""}"##)
        #expect(!plain.usesOAuth)
    }

    @Test func aTestAnswerCarriesNeedsLogin() throws {
        let answer = try decode(
            IntegrationTest.self, #"{"ok":false,"tools":[],"error":"sign in to this service again","needs_login":true}"#)
        #expect(answer.needsLogin)
        #expect(try !decode(IntegrationTest.self, #"{"ok":true,"tools":["a"]}"#).needsLogin)
    }

    @Test func beginCompleteAndStatusReadTheDaemonsAnswers() throws {
        let begun = try decode(
            OAuthBegun.self,
            #"{"authorize_url":"https://mcp.linear.app/authorize?x=1","state":"s1","expires_at":1760000000000}"#)
        #expect(begun.authorizeUrl == "https://mcp.linear.app/authorize?x=1")
        #expect(begun.state == "s1")
        let done = try decode(
            OAuthCompleted.self,
            #"{"id":"i1","name":"linear","created":true,"status":"connected","expires_at":null}"#)
        #expect(done.created && done.name == "linear")
        let list = try decode(
            [OAuthStatus].self,
            #"[{"id":"a","name":"a","status":"connected","expires_at":5,"scope":"read"},{"id":"b","name":"b","status":"needs_login"},{"id":"c","name":"c","status":"not_connected"},{"id":"d","name":"d","status":"something_new"},{"id":"e","name":"e","status":"refresh_error","error":"the service answered HTTP 503"}]"#)
        #expect(list.map(\.connection) == [.connected, .needsLogin, .notConnected, .notConnected, .refreshError])
        #expect(list[4].error == "the service answered HTTP 503")
        #expect(list[0].error == nil)
    }

    @Test func aDraftGoesOutAsTheAddBodyAndAnExistingOneAsItsId() throws {
        struct Draft: Encodable { var draft: NewIntegration }
        let body = try json(Draft(draft: NewIntegration(name: "linear", kind: .http, url: "https://mcp.linear.app/mcp")))
        let draft = try #require(body["draft"] as? [String: Any])
        #expect(draft["name"] as? String == "linear")
        #expect(draft["kind"] as? String == "http")
        #expect(draft["url"] as? String == "https://mcp.linear.app/mcp")
        // The draft carries no key and no header: the sign-in brings the token.
        #expect(draft["headers"] == nil && draft["env"] == nil)
    }

    // MARK: the way back

    @Test func theCallbackAddressGivesCodeAndState() throws {
        let url = try #require(URL(string: "bandito://oauth/callback?code=abc%20def&state=S1&iss=https%3A%2F%2Fmcp.example"))
        let callback = try #require(OAuthCallback.parse(url))
        #expect(callback.code == "abc def")
        #expect(callback.state == "S1")
        #expect(callback.iss == "https://mcp.example")
        #expect(callback.error == nil)
    }

    @Test func aDeniedCallbackCarriesTheError() throws {
        let url = try #require(URL(string: "bandito://oauth/callback?error=access_denied&state=S1"))
        let callback = try #require(OAuthCallback.parse(url))
        #expect(callback.error == "access_denied")
        #expect(callback.code == nil)
    }

    @Test func onlyOurOwnCallbackAddressIsOne() throws {
        for text in [
            "https://oauth/callback?code=a&state=b",
            "bandito://oauth/other?code=a&state=b",
            "bandito://elsewhere/callback?code=a&state=b",
            "bandito://oauth/callback/extra?code=a&state=b",
            "banditoo://oauth/callback?code=a&state=b",
            "bandito://oauth/callback",
        ] {
            #expect(OAuthCallback.parse(try #require(URL(string: text))) == nil, "\(text)")
        }
    }

    @Test func valuesTooLongToBeRealAreDropped() throws {
        let long = String(repeating: "a", count: 5000)
        let url = try #require(URL(string: "bandito://oauth/callback?code=\(long)&state=\(long)"))
        let callback = try #require(OAuthCallback.parse(url))
        #expect(callback.code == nil && callback.state == nil)
    }
}
