import Testing

@testable import BanditoUI

/// Every "hand this to another mode" field is taken exactly once: the first take returns the value and clears it.
@MainActor
@Suite struct PendingActionTests {
    @Test func terminalCommandIsTakenOnce() {
        let router = Router()
        router.pendingTerminalCommand = "curl -fsSL https://example.com/install.sh | sh"
        #expect(router.takeTerminalCommand() == "curl -fsSL https://example.com/install.sh | sh")
        #expect(router.takeTerminalCommand() == nil)
        #expect(router.pendingTerminalCommand == nil)
    }

    @Test func terminalCwdIsTakenOnce() {
        let router = Router()
        router.pendingTerminalCwd = "/home/me/billing"
        #expect(router.takeTerminalCwd() == "/home/me/billing")
        #expect(router.takeTerminalCwd() == nil)
    }

    @Test func agentCwdIsTakenOnce() {
        let router = Router()
        router.pendingAgentCwd = "/home/me/shop"
        #expect(router.takeAgentCwd() == "/home/me/shop")
        #expect(router.takeAgentCwd() == nil)
    }

    @Test func composerTextIsTakenOnce() {
        let router = Router()
        router.pendingComposerText = "Ask about this place"
        #expect(router.takeComposerText() == "Ask about this place")
        #expect(router.takeComposerText() == nil)
    }

    @Test func previewPortIsTakenOnce() {
        let router = Router()
        router.pendingPreviewPort = 5173
        #expect(router.takePreviewPort() == 5173)
        #expect(router.takePreviewPort() == nil)
    }

    @Test func takingDoesNotTouchOtherPendingFields() {
        let router = Router()
        router.pendingTerminalCwd = "/a"
        router.pendingAgentCwd = "/b"
        _ = router.takeTerminalCwd()
        #expect(router.pendingAgentCwd == "/b")
    }

    @Test func focusComposerIsConsumedByTheThread() {
        let router = Router()
        router.requestComposerFocus()
        #expect(router.takeComposerFocus())
        #expect(!router.takeComposerFocus())
    }

    @Test func inspectorTabIsKeptInTheRouter() {
        let router = Router()
        #expect(router.inspectorTab == .details)
        router.openInspector(.memory)
        #expect(router.inspectorOpen)
        #expect(router.inspectorTab == .memory)
    }
}
