import Foundation
import Testing

@testable import BanditoKit

@Suite struct BrowserWheelTests {
    // MARK: units

    @Test func aTrackpadDeltaIsPixelsWithTheSignFlipped() {
        let d = WheelUnits.pixels(scrollingDeltaX: 3, scrollingDeltaY: -12, precise: true)
        #expect(d.x == -3)
        #expect(d.y == 12)
    }

    @Test func aMouseWheelLineIsFortyPixels() {
        let d = WheelUnits.pixels(scrollingDeltaX: 0, scrollingDeltaY: -2, precise: false)
        #expect(d.y == 80)
        #expect(d.x == 0)
    }

    // MARK: batches

    @Test func eventsAreMergedIntoOneCommandAtTheLatestPoint() {
        var batch = WheelBatch()
        #expect(batch.isEmpty)
        batch.add(x: 10, y: 20, deltaX: 0, deltaY: 5, modifiers: [])
        batch.add(x: 30, y: 40, deltaX: 2, deltaY: 7, modifiers: [.shift])
        let out = batch.take()
        #expect(out == WheelBatch.Pending(x: 30, y: 40, deltaX: 2, deltaY: 12, modifiers: [.shift]))
        #expect(batch.isEmpty)
        #expect(batch.take() == nil)
    }

    @Test func zeroAndBrokenEventsAreIgnored() {
        var batch = WheelBatch()
        batch.add(x: 1, y: 1, deltaX: 0, deltaY: 0, modifiers: [])
        batch.add(x: 1, y: 1, deltaX: .nan, deltaY: 3, modifiers: [])
        batch.add(x: .infinity, y: 1, deltaX: 1, deltaY: 3, modifiers: [])
        #expect(batch.isEmpty)
    }

    @Test func oneCommandCarriesAtMostTheCapAndKeepsTheRest() {
        var batch = WheelBatch()
        batch.add(x: 5, y: 6, deltaX: 0, deltaY: 9_000, modifiers: [])
        let first = batch.take()
        #expect(first?.deltaY == WheelBatch.maxDelta)
        #expect(batch.take()?.deltaY == WheelBatch.maxDelta)
        let last = batch.take()
        #expect(last?.deltaY == 9_000 - 2 * WheelBatch.maxDelta)
        #expect(last?.x == 5)
        #expect(batch.take() == nil)
    }

    @Test func clearDropsWhatWaits() {
        var batch = WheelBatch()
        batch.add(x: 1, y: 1, deltaX: 1, deltaY: 1, modifiers: [])
        batch.clear()
        #expect(batch.isEmpty)
    }

    @Test func theCommandRateIsAtMostSixtyPerSecond() {
        #expect(WheelBatch.interval >= .milliseconds(16))
    }

    // MARK: swipe or scroll

    @Test func aMouseWheelAlwaysScrolls() {
        var g = WheelGesture()
        let out = g.feed(deltaX: 200, deltaY: 0, phase: .none, swipeEnabled: true)
        #expect(out.x == 200)
        #expect(!g.isSwipe)
    }

    @Test func aVerticalGestureScrollsFromTheFirstPointsOn() {
        var g = WheelGesture()
        let first = g.feed(deltaX: 0, deltaY: 3, phase: .began, swipeEnabled: true)
        #expect(first.y == 0, "held until the gesture is clear")
        let second = g.feed(deltaX: 1, deltaY: 9, phase: .changed, swipeEnabled: true)
        #expect(second.y == 12, "what was held goes out with the deciding event")
        #expect(second.x == 1)
        let third = g.feed(deltaX: 0, deltaY: 4, phase: .changed, swipeEnabled: true)
        #expect(third.y == 4)
        let momentum = g.feed(deltaX: 0, deltaY: 2, phase: .momentum, swipeEnabled: true)
        #expect(momentum.y == 2, "the coasting is sent too")
    }

    @Test func aSidewaysGestureIsASwipeAndNothingIsSent() {
        var g = WheelGesture()
        var sent = 0.0
        for dx in [4.0, 6, 10, 20, 30] {
            let out = g.feed(deltaX: dx, deltaY: 1, phase: dx == 4 ? .began : .changed, swipeEnabled: true)
            sent += abs(out.x) + abs(out.y)
        }
        #expect(g.isSwipe)
        #expect(sent == 0)
        let momentum = g.feed(deltaX: 15, deltaY: 0, phase: .momentum, swipeEnabled: true)
        #expect(momentum.x == 0, "the tail of a swipe is not scrolled either")
    }

    @Test func aNewGestureStartsFresh() {
        var g = WheelGesture()
        _ = g.feed(deltaX: 20, deltaY: 0, phase: .began, swipeEnabled: true)
        #expect(g.isSwipe)
        let next = g.feed(deltaX: 0, deltaY: 20, phase: .began, swipeEnabled: true)
        #expect(!g.isSwipe)
        #expect(next.y == 20)
    }

    @Test func aTinyTouchIsAScrollWhenItEnds() {
        var g = WheelGesture()
        let a = g.feed(deltaX: 0, deltaY: 2, phase: .began, swipeEnabled: true)
        #expect(a.y == 0)
        let b = g.feed(deltaX: 0, deltaY: 1, phase: .ended, swipeEnabled: true)
        #expect(b.y == 3)
    }

    @Test func withTheSwipeOffEverythingScrolls() {
        var g = WheelGesture()
        let out = g.feed(deltaX: 30, deltaY: 0, phase: .began, swipeEnabled: false)
        #expect(out.x == 30)
        #expect(!g.isSwipe)
    }

    @Test func aDiagonalGestureScrolls() {
        var g = WheelGesture()
        let out = g.feed(deltaX: 10, deltaY: 8, phase: .began, swipeEnabled: true)
        #expect(!g.isSwipe)
        #expect(out.x == 10)
        #expect(out.y == 8)
    }

    @Test func aSidewaysGestureWithNowhereToGoScrollsThePage() {
        var g = WheelGesture()
        var sent = 0.0
        for dx in [-4.0, -6, -10, -20] {
            let out = g.feed(
                deltaX: dx, deltaY: 0, phase: dx == -4 ? .began : .changed, swipeEnabled: true, fingerX: -dx,
                canSwipe: { back in !back })
            sent += out.x
        }
        // The fingers moved right (back) and there is no earlier page: all of it goes to the page.
        #expect(!g.isSwipe)
        #expect(sent == -40)
    }

    @Test func aSidewaysGestureThatHasAPageToGoToIsASwipe() {
        var g = WheelGesture()
        var sent = 0.0
        for dx in [-4.0, -6, -10] {
            sent += g.feed(
                deltaX: dx, deltaY: 0, phase: dx == -4 ? .began : .changed, swipeEnabled: true, fingerX: -dx,
                canSwipe: { back in back }
            ).x
        }
        #expect(g.isSwipe)
        #expect(sent == 0)
    }

    // MARK: the wheel command

    @Test func theWheelCommandCarriesPositionAndDeltasAndNoButton() {
        let command = CDPCommand.mouse(
            type: .mouseWheel, x: 12, y: 34, button: .none, clickCount: 0, deltaX: 5, deltaY: -60, modifiers: [])
        #expect(command.method == "Input.dispatchMouseEvent")
        let p = command.params
        #expect(p["type"]?.string == "mouseWheel")
        #expect(p["x"]?.numberValue == 12)
        #expect(p["deltaY"]?.numberValue == -60)
        #expect(p["buttons"]?.numberValue == 0)
    }
}

@MainActor
@Suite struct WheelSenderTests {
    @Test func eventsAreSentAsMergedBatchesOneAtATime() async throws {
        var sent: [WheelBatch.Pending] = []
        let sender = WheelSender(interval: .milliseconds(5)) { sent.append($0) }
        for _ in 0..<15 {
            sender.add(x: 900, y: 500, deltaX: 0, deltaY: 200, modifiers: [])
        }
        // Waits for the loop to drain instead of a fixed sleep: under a loaded test run the last tick can be late.
        let deadline = ContinuousClock.now + .seconds(20)
        while !(sender.isIdle && sent.reduce(0) { $0 + $1.deltaY } == 3000), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!sent.isEmpty)
        #expect(sent.reduce(0) { $0 + $1.deltaY } == 3000, "nothing is lost in merging")
        #expect(sent.allSatisfy { $0.x == 900 && $0.y == 500 })
        #expect(sender.isIdle)
    }

    @Test func aLaterBurstStartsTheLoopAgain() async throws {
        var total = 0.0
        let sender = WheelSender(interval: .milliseconds(5)) { total += $0.deltaY }
        sender.add(x: 1, y: 1, deltaX: 0, deltaY: 10, modifiers: [])
        try await Task.sleep(for: .milliseconds(60))
        sender.add(x: 1, y: 1, deltaX: 0, deltaY: 5, modifiers: [])
        try await Task.sleep(for: .milliseconds(60))
        #expect(total == 15)
    }

    @Test func stopDropsWhatWaits() async throws {
        var total = 0.0
        let sender = WheelSender(interval: .milliseconds(20)) { total += $0.deltaY }
        sender.add(x: 1, y: 1, deltaX: 0, deltaY: 10, modifiers: [])
        sender.stop()
        try await Task.sleep(for: .milliseconds(80))
        #expect(total == 0)
        sender.add(x: 1, y: 1, deltaX: 0, deltaY: 7, modifiers: [])
        // A busy CI runner can be late by far more than one interval: wait for the delivery, up to 2 s.
        for _ in 0..<100 where total != 7 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(total == 7)
    }
}
