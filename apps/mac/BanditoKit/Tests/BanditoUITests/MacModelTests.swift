import Testing

@testable import BanditoUI

@Suite struct MacModelTests {
    @Test func aHardwareIdentifierNamesItsFamily() {
        #expect(MacModel.name(hardwareModel: "MacBookPro18,3") == "MacBook Pro")
        #expect(MacModel.name(hardwareModel: "MacBookAir10,1") == "MacBook Air")
        #expect(MacModel.name(hardwareModel: "MacBook10,1") == "MacBook")
        #expect(MacModel.name(hardwareModel: "Macmini9,1") == "Mac mini")
        #expect(MacModel.name(hardwareModel: "iMac21,1") == "iMac")
        #expect(MacModel.name(hardwareModel: "MacPro7,1") == "Mac Pro")
    }

    @Test func anAppleSiliconIdentifierNamesNoFamily() {
        #expect(MacModel.name(hardwareModel: "Mac15,3") == nil)
        #expect(MacModel.name(hardwareModel: "") == nil)
        #expect(MacModel.name(hardwareModel: nil) == nil)
    }

    @Test func withoutAFamilyTheDeviceNameDecides() {
        #expect(MacModel.current(hardwareModel: "Mac15,3", deviceName: "Ann's MacBook Air") == "MacBook Air")
        #expect(MacModel.current(hardwareModel: nil, deviceName: "Ann's Mac") == nil)
    }

    @Test func theIdentifierWinsOverTheName() {
        #expect(MacModel.current(hardwareModel: "Macmini9,1", deviceName: "Ann's MacBook Pro") == "Mac mini")
    }

    @Test func theSymbolFollowsTheModel() {
        #expect(DeviceIcon.symbol(platform: nil, name: "MacBook Air") == "laptopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Mac mini") == "desktopcomputer")
    }
}
