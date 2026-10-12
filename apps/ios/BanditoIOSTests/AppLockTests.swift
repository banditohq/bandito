import Foundation
import SwiftUI
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The Face ID lock's rule for when to ask again, and the lock state that follows it.
@MainActor
@Suite struct AppLockTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func nothingIsAskedWhileTheLockIsOff() {
        let away = start.addingTimeInterval(3600)
        #expect(!AppLockPolicy.requiresUnlock(enabled: false, backgroundedAt: start, returnedAt: away, timeout: .oneMinute))
    }

    @Test func aShortAbsenceDoesNotLock() {
        let back = start.addingTimeInterval(59.9)
        #expect(!AppLockPolicy.requiresUnlock(enabled: true, backgroundedAt: start, returnedAt: back, timeout: .oneMinute))
    }

    @Test func reachingTheTimeoutLocksForEachChoice() {
        func locks(after seconds: Double, _ timeout: LockTimeout) -> Bool {
            AppLockPolicy.requiresUnlock(
                enabled: true, backgroundedAt: start, returnedAt: start.addingTimeInterval(seconds), timeout: timeout)
        }
        #expect(locks(after: 60, .oneMinute))
        #expect(!locks(after: 299.9, .fiveMinutes))
        #expect(locks(after: 300, .fiveMinutes))
        #expect(!locks(after: 899, .fifteenMinutes))
        #expect(locks(after: 900, .fifteenMinutes))
    }

    @Test func aColdStartLocksWhenTheLockIsOn() {
        let lock = AppLock()
        lock.start(enabled: true)
        #expect(lock.isLocked)
        lock.unlock()
        #expect(!lock.isLocked)
    }

    @Test func aColdStartIsOpenWhenTheLockIsOff() {
        let lock = AppLock()
        lock.start(enabled: false)
        #expect(!lock.isLocked)
    }

    @Test func returningAfterTheTimeoutLocksAgain() {
        let lock = AppLock()
        lock.start(enabled: false)
        lock.scenePhaseChanged(to: .background, enabled: true, timeout: .fiveMinutes, now: start)
        lock.scenePhaseChanged(to: .active, enabled: true, timeout: .fiveMinutes, now: start.addingTimeInterval(299))
        #expect(!lock.isLocked)

        lock.scenePhaseChanged(to: .background, enabled: true, timeout: .fiveMinutes, now: start.addingTimeInterval(400))
        lock.scenePhaseChanged(to: .active, enabled: true, timeout: .fiveMinutes, now: start.addingTimeInterval(700))
        #expect(lock.isLocked)
    }

    @Test func aReturnWithTheLockOffDoesNotLock() {
        let lock = AppLock()
        lock.scenePhaseChanged(to: .background, enabled: false, timeout: .oneMinute, now: start)
        lock.scenePhaseChanged(to: .active, enabled: false, timeout: .oneMinute, now: start.addingTimeInterval(3600))
        #expect(!lock.isLocked)
    }

    @Test func inactiveDoesNotStartTheClock() {
        // The system's own sheets (the Face ID prompt, the app switcher) make the scene inactive, not background.
        let lock = AppLock()
        lock.scenePhaseChanged(to: .inactive, enabled: true, timeout: .oneMinute, now: start)
        lock.scenePhaseChanged(to: .active, enabled: true, timeout: .oneMinute, now: start.addingTimeInterval(600))
        #expect(!lock.isLocked)
    }
}
