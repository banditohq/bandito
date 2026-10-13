import Testing

@testable import BanditoUI

@Suite struct WelcomeTimelineTests {
    @Test func demoStartsEmpty() {
        let frame = WelcomeTimeline.demo(at: 0)
        #expect(!frame.userMessageVisible)
        #expect(!frame.typingVisible)
        #expect(frame.visibleCommands == 0)
        #expect(!frame.approvalVisible)
        #expect(!frame.allowPressed)
        #expect(!frame.resultVisible)
        #expect(!frame.confettiActive)
    }

    @Test func demoFollowsTheScriptInOrder() {
        #expect(WelcomeTimeline.demo(at: 0.6).userMessageVisible)
        #expect(!WelcomeTimeline.demo(at: 1.0).typingVisible)
        #expect(WelcomeTimeline.demo(at: 1.3).typingVisible)
        #expect(WelcomeTimeline.demo(at: 2.4).typingVisible == false)
        #expect(WelcomeTimeline.demo(at: 2.5).visibleCommands == 1)
        #expect(WelcomeTimeline.demo(at: 3.1).visibleCommands == 2)
        #expect(WelcomeTimeline.demo(at: 3.7).visibleCommands == 3)
        #expect(WelcomeTimeline.demo(at: 4.3).approvalVisible == false)
        #expect(WelcomeTimeline.demo(at: 4.4).approvalVisible)
        #expect(WelcomeTimeline.demo(at: 6.4).allowPressed == false)
        #expect(WelcomeTimeline.demo(at: 6.5).allowPressed)
        #expect(WelcomeTimeline.demo(at: 6.99).resultVisible == false)
        #expect(WelcomeTimeline.demo(at: 7.0).resultVisible)
        #expect(WelcomeTimeline.demo(at: 7.05).confettiActive)
    }

    @Test func demoOnlyEverGainsStepsAsTimePasses() {
        var previous = WelcomeTimeline.demo(at: 0)
        var t = 0.0
        while t <= 10 {
            let current = WelcomeTimeline.demo(at: t)
            #expect(!previous.userMessageVisible || current.userMessageVisible)
            #expect(previous.visibleCommands <= current.visibleCommands)
            #expect(!previous.approvalVisible || current.approvalVisible)
            #expect(!previous.allowPressed || current.allowPressed)
            #expect(!previous.resultVisible || current.resultVisible)
            #expect(!previous.confettiActive || current.confettiActive)
            previous = current
            t += 0.05
        }
    }

    @Test func finalFrameIsTheStaticEndState() {
        let frame = WelcomeTimeline.demo(at: 60)
        #expect(frame.userMessageVisible && frame.approvalVisible && frame.resultVisible)
        #expect(frame.visibleCommands == 3)
        #expect(frame == WelcomeTimeline.finalFrame)
    }

    @Test func entranceRisesFromZeroToOneAfterItsStart() {
        #expect(WelcomeTimeline.entrance(at: 0.5, start: 0.6) == 0)
        #expect(abs(WelcomeTimeline.entrance(at: 0.6 + 0.175, start: 0.6) - 0.5) < 0.0001)
        #expect(WelcomeTimeline.entrance(at: 2, start: 0.6) == 1)
        #expect(WelcomeTimeline.entrance(at: 1, start: 1, duration: 0) == 1)
    }

    @Test func confettiHasFourteenPiecesWithinSpread() {
        let pieces = ConfettiPlan.pieces(count: 14)
        #expect(pieces.count == 14)
        for piece in pieces {
            // dx spans ±150; dy spans -170...90 because the burst is lifted by 40.
            #expect(piece.dx >= -150 && piece.dx <= 150)
            #expect(piece.dy >= -170 && piece.dy <= 90)
            #expect(piece.colorIndex >= 0 && piece.colorIndex < ConfettiPlan.colorCount)
        }
        #expect(ConfettiPlan.pieces(count: 20).count == 20)
    }
}
