import Testing

@testable import BanditoKit

@Suite struct ConsentTimingTests {
    @Test func neverCoversTheIntroduction() {
        #expect(!ConsentTiming.mayShow(introductionActive: true, introductionWasDoneAtLaunch: true, firstReplyDone: true, draftIsEmpty: true))
    }

    @Test func aLaunchAfterTheIntroductionShowsItAtOnce() {
        #expect(ConsentTiming.mayShow(introductionActive: false, introductionWasDoneAtLaunch: true, firstReplyDone: false, draftIsEmpty: false))
    }

    @Test func rightAfterTheIntroductionItWaitsForTheFirstReply() {
        #expect(!ConsentTiming.mayShow(introductionActive: false, introductionWasDoneAtLaunch: false, firstReplyDone: false, draftIsEmpty: true))
    }

    @Test func afterTheFirstReplyItWaitsUntilThePersonStopsTyping() {
        #expect(!ConsentTiming.mayShow(introductionActive: false, introductionWasDoneAtLaunch: false, firstReplyDone: true, draftIsEmpty: false))
        #expect(ConsentTiming.mayShow(introductionActive: false, introductionWasDoneAtLaunch: false, firstReplyDone: true, draftIsEmpty: true))
    }
}
