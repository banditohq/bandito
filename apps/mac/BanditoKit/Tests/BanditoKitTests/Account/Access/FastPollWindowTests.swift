import Foundation
import Testing

@testable import BanditoKit

@Suite struct FastPollWindowTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aWindowIsOpenForItsLengthAndThenClosed() {
        var window = FastPollWindow(length: 180, limit: 600)
        #expect(!window.isOpen(at: t0))
        window.open(at: t0)
        #expect(window.isOpen(at: t0.addingTimeInterval(179)))
        #expect(!window.isOpen(at: t0.addingTimeInterval(181)))
    }

    @Test func extendingKeepsItOpenButNeverPastTheLimitInARow() {
        var window = FastPollWindow(length: 180, limit: 600)
        window.open(at: t0)
        for step in stride(from: 100.0, through: 700, by: 100) { window.extendIfOpen(at: t0.addingTimeInterval(step)) }
        #expect(window.isOpen(at: t0.addingTimeInterval(599)))
        #expect(!window.isOpen(at: t0.addingTimeInterval(601)))
        // Once closed, waiting alone does not start another; an event does.
        window.extendIfOpen(at: t0.addingTimeInterval(700))
        #expect(!window.isOpen(at: t0.addingTimeInterval(701)))
        window.open(at: t0.addingTimeInterval(702))
        #expect(window.isOpen(at: t0.addingTimeInterval(703)))
    }

    @Test func closingEndsItAtOnce() {
        var window = FastPollWindow(length: 180, limit: 600)
        window.open(at: t0)
        window.close()
        #expect(!window.isOpen(at: t0))
    }
}
