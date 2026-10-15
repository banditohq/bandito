@testable import BanditoUI
import Foundation
import Testing

/// A device's line in the account: this Mac is always online, another one is online for five minutes after it was seen,
/// and a device without a time says nothing.
@Suite struct DevicePresenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thisDeviceIsAlwaysOnline() {
        #expect(DevicePresence.line(current: true, lastSeen: nil, now: now) == .online)
        #expect(DevicePresence.line(current: true, lastSeen: now.addingTimeInterval(-86_400), now: now) == .online)
    }

    @Test func aDeviceSeenRecentlyIsOnline() {
        #expect(DevicePresence.line(current: false, lastSeen: now.addingTimeInterval(-60), now: now) == .online)
        #expect(DevicePresence.line(current: false, lastSeen: now.addingTimeInterval(-299), now: now) == .online)
    }

    @Test func aDeviceSeenLongAgoSaysWhen() {
        let seen = now.addingTimeInterval(-3_600)
        #expect(DevicePresence.line(current: false, lastSeen: seen, now: now) == .lastSeen(seen))
        #expect(DevicePresence.line(current: false, lastSeen: now.addingTimeInterval(-300), now: now) == .lastSeen(now.addingTimeInterval(-300)))
    }

    @Test func aDeviceWithoutATimeSaysNothing() {
        #expect(DevicePresence.line(current: false, lastSeen: nil, now: now) == .none)
    }
}
