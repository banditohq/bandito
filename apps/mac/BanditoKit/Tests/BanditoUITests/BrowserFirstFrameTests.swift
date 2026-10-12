import Foundation
import Testing

@testable import BanditoUI

@Suite struct BrowserFirstFrameRuleTests {
    @Test func aScreencastFrameMeansNoStill() {
        #expect(!BrowserFirstFrameRule.needsStill(sawFrame: true, isCurrentClient: true))
    }

    @Test func noFrameInTimeAsksForAStill() {
        #expect(BrowserFirstFrameRule.needsStill(sawFrame: false, isCurrentClient: true))
    }

    @Test func aReplacedOrClosedConnectionAsksForNothing() {
        #expect(!BrowserFirstFrameRule.needsStill(sawFrame: false, isCurrentClient: false))
        #expect(!BrowserFirstFrameRule.needsStill(sawFrame: true, isCurrentClient: false))
    }

    @Test func theWaitIsOneAndAHalfSeconds() {
        #expect(BrowserFirstFrameRule.screencastWait == .milliseconds(1500))
    }
}
