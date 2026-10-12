@testable import BanditoKit
import Foundation
import Testing

/// The server settings on the wire (docs/ARCHITECTURE.md#server-settings): the reply of `server.settings_get` and
/// `server.settings_set` read with the app's decoder, the patch the app sends, and the `server.settings_changed` event.
@Suite struct ServerSettingsWireTests {
    private static let reply = #"""
    {
      "settings": {
        "screen_idle_minutes": 45, "max_running_agents": 0, "backup_every_hours": 12, "backup_keep": 20,
        "auto_update": "install", "update_channel": "stable", "default_approval_mode": "always"
      },
      "defaults": {
        "screen_idle_minutes": 30, "max_running_agents": 0, "backup_every_hours": 24, "backup_keep": 14,
        "auto_update": "notify", "update_channel": "stable", "default_approval_mode": "risky"
      }
    }
    """#

    @Test func replyReadsTheSettingsAndTheDefaults() throws {
        let snapshot = try RPCClient.decoder.decode(ServerSettingsSnapshot.self, from: Data(Self.reply.utf8))
        #expect(snapshot.settings.screenIdleMinutes == 45)
        #expect(snapshot.settings.maxRunningAgents == 0)
        #expect(snapshot.settings.backupEveryHours == 12)
        #expect(snapshot.settings.backupKeep == 20)
        #expect(snapshot.settings.autoUpdate == .install)
        #expect(snapshot.settings.updateChannel == "stable")
        #expect(snapshot.settings.defaultApprovalMode == .always)
        #expect(snapshot.defaults.defaultApprovalMode == .risky)
        #expect(snapshot.defaults.autoUpdate == .notify)
    }

    @Test func unknownAutoUpdateFallsBackToNotify() throws {
        let raw = Self.reply.replacingOccurrences(of: "\"install\"", with: "\"weekly\"")
        let snapshot = try RPCClient.decoder.decode(ServerSettingsSnapshot.self, from: Data(raw.utf8))
        #expect(snapshot.settings.autoUpdate == .notify)
    }

    @Test func unknownApprovalModeFallsBackToAlways() throws {
        let raw = Self.reply.replacingOccurrences(of: "\"always\"", with: "\"sometimes\"")
        let snapshot = try RPCClient.decoder.decode(ServerSettingsSnapshot.self, from: Data(raw.utf8))
        #expect(snapshot.settings.defaultApprovalMode == .always)
    }

    @Test func patchSendsOnlyTheFieldsItSets() throws {
        let patch = ServerSettingsPatch(screenIdleMinutes: 10, autoUpdate: .off)
        let data = try RPCClient.encoder.encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["screen_idle_minutes", "auto_update"])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"screen_idle_minutes\":10"))
        #expect(json.contains("\"auto_update\":\"off\""))
        #expect(!json.contains("max_running_agents"))
        #expect(!json.contains("backup_keep"))
        #expect(!json.contains("default_approval_mode"))
    }

    @Test func emptyPatchIsEmpty() {
        #expect(ServerSettingsPatch().isEmpty)
        #expect(!ServerSettingsPatch(backupKeep: 3).isEmpty)
    }

    @Test func settingsChangedEventDecodesItsKeys() throws {
        let raw = #"{"seq":9,"agent_id":"","ts":1,"kind":"server.settings_changed","payload":{"keys":["backup_keep","auto_update"]}}"#
        let event = try RPCClient.decoder.decode(Event.self, from: Data(raw.utf8))
        guard case .serverSettingsChanged(let keys) = event.body else {
            Issue.record("wrong body \(event.body)")
            return
        }
        #expect(keys == ["backup_keep", "auto_update"])
    }
}
