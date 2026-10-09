import Foundation
import Testing

@testable import BanditoKit

@Suite struct DeviceModelTests {
    @Test func currentAndPlatformAreOptionalForOlderDaemons() throws {
        let json = #"{"id":"d1","name":"Ann's MacBook Pro","created_at":1,"last_seen_at":null}"#
        let device = try RPCClient.decoder.decode(Device.self, from: Data(json.utf8))
        #expect(device.current == nil)
        #expect(device.platform == nil)
    }

    @Test func currentAndPlatformAreReadWhenTheDaemonSendsThem() throws {
        let json = #"{"id":"d1","name":"Ann","created_at":1,"last_seen_at":2,"current":true,"platform":"macos"}"#
        let device = try RPCClient.decoder.decode(Device.self, from: Data(json.utf8))
        #expect(device.current == true)
        #expect(device.platform == "macos")
    }
}
