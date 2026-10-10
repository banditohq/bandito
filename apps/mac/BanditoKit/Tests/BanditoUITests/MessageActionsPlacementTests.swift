import SwiftUI
import Testing

@testable import BanditoUI

@Suite struct MessageActionsPlacementTests {
    @Test func agentRowIsOnTheLeftUnderTheBubbleAndPersonsRowOnTheRight() {
        #expect(MessageActionsPlacement.edge(isUser: false) == .leading)
        #expect(MessageActionsPlacement.edge(isUser: true) == .trailing)
    }

    @Test func hoverShowsTheRowInFull() {
        #expect(MessageActionsPlacement.opacity(
            hovering: true, open: false, selectingText: false, isUser: false, isLastAgent: false) == 1)
        #expect(MessageActionsPlacement.opacity(
            hovering: true, open: false, selectingText: false, isUser: true, isLastAgent: false) == 1)
    }

    @Test func rowStaysWhileAPopoverOrMenuIsOpenEvenWithoutHover() {
        #expect(MessageActionsPlacement.opacity(
            hovering: false, open: true, selectingText: false, isUser: true, isLastAgent: false) == 1)
        #expect(MessageActionsPlacement.opacity(
            hovering: false, open: true, selectingText: true, isUser: false, isLastAgent: false) == 1)
    }

    @Test func rowDoesNotAppearWhileTextIsBeingSelectedWithTheMouse() {
        #expect(MessageActionsPlacement.opacity(
            hovering: true, open: false, selectingText: true, isUser: false, isLastAgent: false) == 0)
        #expect(MessageActionsPlacement.opacity(
            hovering: true, open: false, selectingText: true, isUser: false, isLastAgent: true) == 0.5)
    }

    @Test func lastAgentMessageKeepsAFaintRowAndOthersHideIt() {
        #expect(MessageActionsPlacement.opacity(
            hovering: false, open: false, selectingText: false, isUser: false, isLastAgent: true) == 0.5)
        #expect(MessageActionsPlacement.opacity(
            hovering: false, open: false, selectingText: false, isUser: false, isLastAgent: false) == 0)
        // The person's own message never keeps a row: only the agent's last answer does.
        #expect(MessageActionsPlacement.opacity(
            hovering: false, open: false, selectingText: false, isUser: true, isLastAgent: true) == 0)
    }

    @Test func rowFitsTheGapBetweenMessagesSoItNeverMovesTheThread() {
        // The thread stacks rows with 12 pt; the row reserves the rest of the 28 pt gap below the bubble.
        #expect(MessageActionsPlacement.threadSpacing == 12)
        #expect(MessageActionsPlacement.reservedBelow + MessageActionsPlacement.threadSpacing
            == MessageActionsPlacement.gapBetweenMessages)
        #expect(MessageActionsPlacement.gapBetweenMessages == 28)
    }
}
