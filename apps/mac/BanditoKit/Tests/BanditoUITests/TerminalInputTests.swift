import Foundation
import Testing

@testable import BanditoUI

@Suite struct TerminalInputBatcherTests {
    @Test func keystrokesInTheWindowAreJoined() {
        var batcher = TerminalInputBatcher()
        #expect(batcher.add(Data("a".utf8), now: 0) == [])
        #expect(batcher.add(Data("b".utf8), now: 0.010) == [])
        #expect(batcher.deadline == 0.016)
        #expect(batcher.flush() == Data("ab".utf8))
        #expect(batcher.deadline == nil)
        #expect(batcher.flush() == nil)
    }

    @Test func aLargePasteIsCutIntoFourKiBChunksAtOnce() {
        var batcher = TerminalInputBatcher()
        let paste = Data(repeating: 0x41, count: 10_000)
        let ready = batcher.add(paste, now: 0)
        #expect(ready.map(\.count) == [4096, 4096])
        #expect(batcher.flush()?.count == 1808)
    }

    @Test func chunksKeepTheByteOrder() {
        var batcher = TerminalInputBatcher()
        let data = Data((0..<9000).map { UInt8($0 % 251) })
        let ready = batcher.add(data, now: 0)
        let rest = batcher.flush() ?? Data()
        #expect(ready.reduce(Data(), +) + rest == data)
    }

    @Test func aBatchStartsItsWindowAtTheFirstByte() {
        var batcher = TerminalInputBatcher()
        _ = batcher.add(Data("x".utf8), now: 1)
        _ = batcher.add(Data("y".utf8), now: 1.015)
        #expect(abs((batcher.deadline ?? 0) - 1.016) < 1e-9)
    }
}

@MainActor
@Suite struct TerminalFontSizeTests {
    @Test func sizeIsClampedToNineThroughTwentyEight() {
        #expect(TerminalFontSize.clamp(5) == 9)
        #expect(TerminalFontSize.clamp(40) == 28)
        #expect(TerminalFontSize.clamp(12.5) == 12.5)
    }

    @Test func pinchScalesAndStaysInRange() {
        #expect(TerminalFontSize.scaled(12, by: 0.5) == 18)
        #expect(TerminalFontSize.scaled(12, by: -0.99) == 9)
        #expect(TerminalFontSize.scaled(27, by: 2) == 28)
    }

    @Test func storeStepsAndPersistsTheSize() {
        let suite = UserDefaults(suiteName: "bandito.tests.\(UUID().uuidString)")!
        let store = TerminalFontStore(defaults: suite)
        #expect(store.size == TerminalFontSize.standard)

        store.bigger()
        #expect(store.size == 13.5)
        store.set(100)
        #expect(store.size == 28)
        store.smaller()
        #expect(store.size == 27)
        store.reset()
        #expect(store.size == 12.5)

        store.set(20)
        let reloaded = TerminalFontStore(defaults: suite)
        #expect(reloaded.size == 20)
    }
}
