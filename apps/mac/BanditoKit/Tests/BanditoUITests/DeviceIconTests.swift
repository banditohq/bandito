import Testing

@testable import BanditoUI

@Suite struct DeviceIconTests {
    @Test func platformDecidesWhenTheServerReportsOne() {
        #expect(DeviceIcon.symbol(platform: "macos", name: "iPhone") == "laptopcomputer")
        #expect(DeviceIcon.symbol(platform: "ios", name: "Ann's Mac") == "iphone")
    }

    @Test func fullModelNamesDecideWithoutAPlatform() {
        #expect(DeviceIcon.symbol(platform: nil, name: "Ann's MacBook Pro") == "laptopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Ann's iPhone") == "iphone")
        #expect(DeviceIcon.symbol(platform: nil, name: "Studio iMac") == "desktopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Mac mini") == "desktopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Mac Studio") == "desktopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Mac Pro") == "desktopcomputer")
    }

    @Test func arbitraryNamesWithMacInThemAreNotLaptops() {
        #expect(DeviceIcon.symbol(platform: nil, name: "Macro pad") == "desktopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Pixel 9") == "desktopcomputer")
        #expect(DeviceIcon.symbol(platform: nil, name: "Ann's Mac") == "desktopcomputer")
    }
}
