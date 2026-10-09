import Testing

@testable import BanditoUI

@MainActor
@Suite struct RouterDraftTests {
    @Test func takingTheDraftSendsItTrimmedAndClearsIt() {
        let router = Router()
        router.drafts["a"] = "  fix the build \n"
        #expect(router.takeDraft(for: "a") == "fix the build")
        #expect(router.drafts["a"] == nil)
        #expect(router.takeDraft(for: "a") == "")
    }

    /// A send that fails goes back to the draft of the agent it was sent to, while the person is on another agent.
    @Test func aFailedSendReturnsToItsOwnAgentNotTheOneOnScreen() {
        let router = Router()
        router.drafts["a"] = "deploy staging"
        let sent = router.takeDraft(for: "a")
        // The person moves on and types for agent b.
        router.drafts["b"] = "question for b"

        router.restoreDraft(sent, for: "a")

        #expect(router.drafts["a"] == "deploy staging")
        #expect(router.drafts["b"] == "question for b", "agent b's draft is untouched")
    }

    /// Text typed into the agent's draft since the send is kept, behind the text that failed.
    @Test func restoredTextComesBeforeWhatWasTypedSince() {
        let router = Router()
        router.drafts["a"] = "first"
        let sent = router.takeDraft(for: "a")
        router.drafts["a"] = "second, typed meanwhile"

        router.restoreDraft(sent, for: "a")

        #expect(router.drafts["a"] == "first\nsecond, typed meanwhile")
    }

    @Test func restoringIntoAnEmptyDraftJustSetsIt() {
        let router = Router()
        router.drafts["a"] = "   "
        router.restoreDraft("hello", for: "a")
        #expect(router.drafts["a"] == "hello")
    }

    @Test func pendingComposerTextAppendsToTheAgentsDraft() {
        let router = Router()
        router.drafts["a"] = "already here"
        router.appendDraft("from the code view", for: "a")
        #expect(router.drafts["a"] == "already here\nfrom the code view")
        router.appendDraft("again", for: "b")
        #expect(router.drafts["b"] == "again")
    }
}
