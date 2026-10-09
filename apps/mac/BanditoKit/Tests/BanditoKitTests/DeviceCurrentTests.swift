import Foundation
import Testing

@testable import BanditoKit

@Suite struct DeviceCurrentTests {
    @Test func daemonWithoutTheFlagLeavesCurrentUnknown() throws {
        let device = try RPCClient.decoder.decode(
            Device.self, from: Data(#"{"id":"d1","name":"Mac","created_at":1}"#.utf8))
        #expect(device.current == nil)
    }

    @Test func currentFlagDecodes() throws {
        let device = try RPCClient.decoder.decode(
            Device.self,
            from: Data(#"{"id":"d1","name":"Mac","created_at":1,"last_seen_at":2,"current":true}"#.utf8))
        #expect(device.current == true)
        #expect(device.lastSeenAt == 2)
    }
}
