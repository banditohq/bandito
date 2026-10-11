import Foundation
import Testing

@testable import BanditoKit

/// The wire of the sign-in with a code (`integrations.device_*`) and the pieces the sheet shows.
@Suite struct IntegrationDeviceWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func anIntegrationAndACatalogEntryReadTheCodeSignIn() throws {
        let row = try decode(
            Integration.self,
            #"{"id":"i1","name":"github","kind":"http","url":"https://api.githubcopilot.com/mcp/","enabled":true,"created_at":1,"auth":"device"}"#)
        #expect(row.auth == .device)
        #expect(row.auth.isDaemonSignIn)
        #expect(IntegrationAuth.oauth.isDaemonSignIn && !IntegrationAuth.none.isDaemonSignIn)
        let entry = try decode(
            IntegrationCatalogEntry.self,
            ##"{"id":"github","name":"GitHub","description_en":"E","description_ru":"Р","kind":"http","url":"https://api.githubcopilot.com/mcp/","docs_url":"https://d","icon":"github","auth":"device","device":{"provider":"github","client_id":"x","scope":"repo"}}"##)
        #expect(entry.usesDevice && !entry.usesOAuth)
    }

    @Test func beginReadsTheCodeThePageAndTheDeadline() throws {
        let begun = try decode(
            DeviceBegun.self,
            #"{"flow_id":"f1","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_at":1760000900000,"interval":5}"#)
        #expect(begun.flowId == "f1" && begun.userCode == "WDJB-MJHT")
        #expect(begun.verificationUri == "https://github.com/login/device")
        #expect(begun.expiresAt == 1_760_000_900_000 && begun.interval == 5)
    }

    @Test func statusReadsEachStateAndAnUnknownOneIsPending() throws {
        func state(_ raw: String) throws -> DeviceFlowState { try decode(DeviceStatus.self, raw).state }
        #expect(try state(#"{"flow_id":"f","state":"pending","user_code":"A","interval":6}"#) == .pending)
        #expect(
            try state(#"{"flow_id":"f","state":"done","id":"i1","name":"github","created":true}"#)
                == .done(integrationID: "i1", name: "github", created: true))
        #expect(
            try state(#"{"flow_id":"f","state":"failed","reason":"denied","error":"refused on the page"}"#)
                == .failed(.denied, detail: "refused on the page"))
        #expect(try state(#"{"flow_id":"f","state":"failed","reason":"something_new"}"#) == .failed(.other, detail: nil))
        #expect(try state(#"{"flow_id":"f","state":"cancelled"}"#) == .cancelled)
        #expect(try state(#"{"flow_id":"f","state":"brand_new"}"#) == .pending)
        let slow = try decode(DeviceStatus.self, #"{"flow_id":"f","state":"pending","interval":11}"#)
        #expect(slow.interval == 11)
    }

    @Test func aDraftAndAFlowIdGoOutAsTheDaemonReadsThem() throws {
        struct Draft: Encodable { var draft: NewIntegration }
        struct Flow: Encodable { var flowId: String }
        let body = try json(Draft(draft: NewIntegration(name: "github", kind: .http, url: "https://api.githubcopilot.com/mcp/")))
        let draft = try #require(body["draft"] as? [String: Any])
        #expect(draft["name"] as? String == "github" && draft["url"] as? String == "https://api.githubcopilot.com/mcp/")
        #expect(draft["headers"] == nil && draft["env"] == nil)
        #expect(try json(Flow(flowId: "f1"))["flow_id"] as? String == "f1")
    }

    @Test func thePageIsHttpsOrThisMacAndShowsHostAndPath() {
        let page = DevicePage("https://github.com/login/device")
        #expect(page?.address == "github.com/login/device" && page?.host == "github.com")
        #expect(DevicePage("https://example.com/")?.address == "example.com")
        #expect(DevicePage("http://localhost:8080/login/device")?.host == "localhost")
        #expect(DevicePage("http://github.com/login/device") == nil)
        #expect(DevicePage("file:///etc/passwd") == nil)
        #expect(DevicePage("javascript:alert(1)") == nil)
        #expect(DevicePage("not a url") == nil)
        #expect(DevicePage("") == nil)
    }

    @Test func theCountdownNeverGoesBelowZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(deviceSecondsLeft(expiresAt: 1_000_000 + 872_400, now: now) == 873)
        #expect(deviceSecondsLeft(expiresAt: 999_000, now: now) == 0)
        #expect(deviceCountdown(seconds: 873) == "14:33")
        #expect(deviceCountdown(seconds: 5) == "0:05")
        #expect(deviceCountdown(seconds: -3) == "0:00")
    }
}
