import CoreGraphics
import Foundation
import Testing

@testable import Bandito

/// Where the chat's list and box sit, and when the chat counts as read: pure rules.
@Suite struct ChatFrameRulesTests {
    let portrait = CGSize(width: 390, height: 844)

    func frames(
        _ size: CGSize? = nil, top: CGFloat = 100, bottom: CGFloat = 34, keyboard: CGFloat? = nil, box: CGFloat = 60
    ) -> ChatFrames {
        ChatFrameRules.frames(size: size ?? portrait, safeTop: top, safeBottom: bottom, keyboardTop: keyboard, boxHeight: box)
    }

    @Test func theBoxIsOnTheBottomEdgeAndTheListFillsTheRest() {
        let result = frames()
        #expect(result.box == CGRect(x: 0, y: 750, width: 390, height: 60))
        #expect(result.list == CGRect(x: 0, y: 100, width: 390, height: 650))
    }

    @Test func theKeyboardLiftsTheBox() {
        let result = frames(keyboard: 500)
        #expect(result.box.maxY == 500)
        #expect(result.list.maxY == result.box.minY)
        #expect(result.list.minY == 100)
    }

    @Test func aKeyboardBelowTheBottomEdgeChangesNothing() {
        #expect(frames(keyboard: 900) == frames())
    }

    @Test func aKeyboardFrameThatIsTooHighToBeTrueDoesNotCarryTheBoxToTheTop() {
        // A frame the system gets wrong for a moment (a screenshot, a trait change): the list keeps its floor.
        for bogus in [CGFloat(0), 50, -300, 120] {
            let result = frames(keyboard: bogus)
            #expect(result.list.height >= ChatFrameRules.listFloor - 0.5, "keyboard at \(bogus): the list is \(result.list.height)")
            #expect(result.box.minY > result.list.minY)
            #expect(result.box.height == 60)
        }
    }

    @Test func aKeyboardThatIsNotANumberIsIgnored() {
        #expect(frames(keyboard: .nan) == frames())
        #expect(frames(keyboard: .infinity) == frames())
        #expect(frames(top: .nan, bottom: .nan, box: .nan).box.maxY.isFinite)
    }

    @Test func aTurnedScreenWithTheKeyboardKeepsRoomForTheList() {
        let landscape = CGSize(width: 844, height: 390)
        let result = frames(landscape, top: 0, bottom: 21, keyboard: 160)
        #expect(result.box.maxY == 160)
        #expect(result.list.height >= 80)
        let tooHigh = frames(landscape, top: 0, bottom: 21, keyboard: 40)
        #expect(tooHigh.list.height >= 80)
    }

    @Test func aBoxTallerThanTheRoomIsCutToIt() {
        let result = frames(box: 5000)
        #expect(result.box.height == 744)
        #expect(result.box.minY == 100)
        #expect(result.list.height == 0)
        #expect(result.box.maxY <= portrait.height)
    }

    @Test func aScreenWithNoSizeDoesNotCrash() {
        let result = frames(.zero, top: 0, bottom: 0, box: 60)
        #expect(result.box.minY >= 0)
        #expect(result.list.height == 0)
        let negative = frames(CGSize(width: -5, height: -5), top: -10, bottom: -10, box: -4)
        #expect(negative.box.height == 0 && negative.list.width == 0)
    }

    // MARK: read

    @Test func aListThatFitsIsAtItsEnd() {
        #expect(ChatSeenRules.endIsVisible(contentHeight: 300, offset: 0, viewport: 600))
        #expect(ChatSeenRules.endIsVisible(contentHeight: 600.4, offset: 0, viewport: 600))
    }

    @Test func aLongListIsAtItsEndOnlyNearTheBottom() {
        #expect(ChatSeenRules.endIsVisible(contentHeight: 3000, offset: 2400, viewport: 600))
        #expect(ChatSeenRules.endIsVisible(contentHeight: 3000, offset: 2370, viewport: 600))
        #expect(!ChatSeenRules.endIsVisible(contentHeight: 3000, offset: 1000, viewport: 600))
        #expect(!ChatSeenRules.endIsVisible(contentHeight: 3000, offset: 0, viewport: 0))
    }

    @Test func aChatCountsAsReadOnlyOnTheScreenOfAnActiveApp() {
        #expect(ChatSeenRules.countsAsRead(visible: true, appActive: true, endVisible: true, openedAtEntry: false))
        #expect(!ChatSeenRules.countsAsRead(visible: false, appActive: true, endVisible: true, openedAtEntry: false))
        #expect(!ChatSeenRules.countsAsRead(visible: true, appActive: false, endVisible: true, openedAtEntry: false))
        #expect(!ChatSeenRules.countsAsRead(visible: true, appActive: true, endVisible: false, openedAtEntry: false))
    }

    @Test func aChatOpenedAtAnEntryCountsAsLookedAtWhereverItIs() {
        #expect(ChatSeenRules.countsAsRead(visible: true, appActive: true, endVisible: false, openedAtEntry: true))
        #expect(!ChatSeenRules.countsAsRead(visible: true, appActive: false, endVisible: false, openedAtEntry: true))
    }
}
