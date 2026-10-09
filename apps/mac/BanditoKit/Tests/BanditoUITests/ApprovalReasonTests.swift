import Testing
@testable import BanditoUI
import BanditoL10n

struct ApprovalReasonTests {
    @Test func knownReasonsReadAsWords() {
        #expect(ApprovalReason.text("risky: rm -r") == L10n.Approval.Why.deleteFolder)
        #expect(ApprovalReason.text("risky: git push") == L10n.Approval.Why.gitPush)
        #expect(ApprovalReason.text("reads credentials: ~/.ssh") == L10n.Approval.Why.credentials(folder: "~/.ssh"))
        #expect(ApprovalReason.text("writes outside /srv/app") == L10n.Approval.Why.outside)
        #expect(ApprovalReason.text("can't check: eval") == L10n.Approval.Why.cantCheck)
        #expect(ApprovalReason.text("rule: git push*") == L10n.Approval.Why.yourRule(rule: "git push*"))
        #expect(ApprovalReason.text("risky: kubectl delete") == L10n.Approval.Why.risky(rule: "kubectl delete"))
    }

    @Test func unknownReasonIsShownAsItCame() {
        #expect(ApprovalReason.text("something new") == L10n.Approval.rule(rule: "something new"))
    }

    @Test func groupTitleFollowsTheCalls() {
        #expect(ToolGroupTitle.text(oks: [true, nil]) == L10n.Thread.runningCommands(count: 2))
        #expect(ToolGroupTitle.text(oks: [false]) == L10n.Thread.notRanCommands(count: 1))
        #expect(ToolGroupTitle.text(oks: [true, false]) == L10n.Thread.ranCommands(count: 2))
    }
}
