import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct WorkbenchTests {
    private let term1 = WorkbenchTab.terminal(sessionID: "s1")
    private let term2 = WorkbenchTab.terminal(sessionID: "s2")
    private let browser = WorkbenchTab.browser
    private let notes = WorkbenchTab.file(path: "/home/me/notes/today.md")

    // MARK: open

    @Test func openAddsTabToFocusedPaneAndOpensPanel() {
        let state = WorkbenchRules.open(term1, in: WorkbenchState())
        #expect(state.isOpen)
        #expect(state.panes[0].tabs == [term1])
        #expect(state.panes[0].selected == term1)
    }

    @Test func openingAnOpenTabSelectsItWithoutDuplicating() {
        var state = WorkbenchRules.open(term1, in: WorkbenchState())
        state = WorkbenchRules.open(browser, in: state)
        state = WorkbenchRules.open(term1, in: state)
        #expect(state.panes[0].tabs == [term1, browser])
        #expect(state.panes[0].selected == term1)
    }

    @Test func openingTabInOtherPaneFocusesThatPane() {
        var state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        state = WorkbenchRules.open(browser, in: state)
        #expect(state.panes[1].tabs == [.details, browser])
        #expect(state.focusedPane == 1)
        state = WorkbenchRules.open(term1, in: state)
        #expect(state.focusedPane == 0)
        #expect(state.panes[0].selected == term1)
        #expect(state.panes[1].tabs.contains(term1) == false)
        #expect(state.allTabs.filter { $0 == term1 }.count == 1)
    }

    // MARK: close

    @Test func closingSelectedTabSelectsTheTabThatMovedIntoItsPlace() {
        var state = WorkbenchRules.open(term1, in: WorkbenchState())
        state = WorkbenchRules.open(term2, in: state)
        state = WorkbenchRules.open(browser, in: state)
        state = WorkbenchRules.select(term1, in: state)
        state = WorkbenchRules.close(term1, in: state)
        #expect(state.panes[0].tabs == [term2, browser])
        #expect(state.panes[0].selected == term2)
    }

    @Test func closingLastSelectedTabSelectsTheTabBeforeIt() {
        var state = WorkbenchRules.open(term1, in: WorkbenchState())
        state = WorkbenchRules.open(term2, in: state)
        state = WorkbenchRules.close(term2, in: state)
        #expect(state.panes[0].tabs == [term1])
        #expect(state.panes[0].selected == term1)
        #expect(state.isOpen)
    }

    @Test func closingUnselectedTabKeepsSelection() {
        var state = WorkbenchRules.open(term1, in: WorkbenchState())
        state = WorkbenchRules.open(term2, in: state)
        state = WorkbenchRules.close(term1, in: state)
        #expect(state.panes[0].tabs == [term2])
        #expect(state.panes[0].selected == term2)
    }

    @Test func closingLastTabOfOnePaneClosesThePanel() {
        let state = WorkbenchRules.close(term1, in: WorkbenchRules.open(term1, in: WorkbenchState()))
        #expect(!state.isOpen)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].tabs.isEmpty)
        #expect(state.panes[0].selected == nil)
    }

    @Test func closingLastTabOfAPaneRemovesThatPaneWhenSplit() {
        var state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        state = WorkbenchRules.open(browser, in: state)
        state = WorkbenchRules.close(.details, in: state)
        #expect(state.panes.count == 2)
        state = WorkbenchRules.close(browser, in: state)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].tabs == [term1])
        #expect(state.isOpen)
        #expect(state.focusedPane == 0)
    }

    @Test func closingUnknownTabChangesNothing() {
        let state = WorkbenchRules.open(term1, in: WorkbenchState())
        #expect(WorkbenchRules.close(browser, in: state) == state)
    }

    // MARK: split and unsplit

    @Test func splitAddsDetailsPaneWhenDetailsIsNotOpen() {
        let state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        #expect(state.panes.count == 2)
        #expect(state.panes[1].tabs == [.details])
        #expect(state.panes[1].selected == .details)
        #expect(state.focusedPane == 1)
    }

    @Test func splitAddsEmptyPaneWhenDetailsIsAlreadyOpen() {
        let state = WorkbenchRules.split(WorkbenchRules.open(.details, in: WorkbenchState()))
        #expect(state.panes.count == 2)
        #expect(state.panes[1].tabs.isEmpty)
        #expect(state.panes[1].selected == nil)
    }

    @Test func splitIsLimitedToTwoPanes() {
        let once = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        #expect(WorkbenchRules.split(once) == once)
    }

    @Test func unsplitJoinsTabsIntoFirstPane() {
        var state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        state = WorkbenchRules.open(browser, in: state)
        state = WorkbenchRules.unsplit(state)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].tabs == [term1, .details, browser])
        #expect(state.panes[0].selected == term1)
        #expect(state.focusedPane == 0)
    }

    @Test func unsplitWithOnePaneChangesNothing() {
        let state = WorkbenchRules.open(term1, in: WorkbenchState())
        #expect(WorkbenchRules.unsplit(state) == state)
    }

    // MARK: move

    @Test func moveTakesTabToOtherPaneAndSelectsIt() {
        var state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        state = WorkbenchRules.open(browser, in: state)
        state = WorkbenchRules.move(browser, toPane: 0, in: state)
        #expect(state.panes[0].tabs == [term1, browser])
        #expect(state.panes[0].selected == browser)
        #expect(state.focusedPane == 0)
        #expect(state.panes[1].tabs == [.details])
    }

    @Test func moveEmptyingSourcePaneRemovesIt() {
        var state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        state = WorkbenchRules.move(.details, toPane: 0, in: state)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].tabs == [term1, .details])
        #expect(state.focusedPane == 0)
    }

    @Test func moveFromFirstPaneEmptiedByMoveFollowsTargetIndex() {
        // Panes: [details] and [term1]. Moving details down empties the first pane, so the target shifts to index 0.
        var state = WorkbenchRules.open(.details, in: WorkbenchState())
        state = WorkbenchRules.split(state)
        state = WorkbenchRules.open(term1, in: state)
        #expect(state.panes.map(\.tabs) == [[.details], [term1]])
        state = WorkbenchRules.move(.details, toPane: 1, in: state)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].tabs == [term1, .details])
        #expect(state.panes[0].selected == .details)
        #expect(state.focusedPane == 0)
    }

    @Test func moveToSamePaneOrMissingTargetChangesNothing() {
        let state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        #expect(WorkbenchRules.move(term1, toPane: 0, in: state) == state)
        #expect(WorkbenchRules.move(term1, toPane: 5, in: state) == state)
        #expect(WorkbenchRules.move(browser, toPane: 1, in: state) == state)
    }

    // MARK: toggle and details

    @Test func toggleOpensDetailsWhenEmptyAndClosesWhenOpen() {
        var state = WorkbenchRules.toggle(WorkbenchState())
        #expect(state.isOpen)
        #expect(state.panes[0].selected == .details)
        #expect(WorkbenchRules.showsDetails(state))
        state = WorkbenchRules.toggle(state)
        #expect(!state.isOpen)
        #expect(!WorkbenchRules.showsDetails(state))
    }

    @Test func toggleReopensLastTabsWithoutChangingThem() {
        var state = WorkbenchRules.open(term1, in: WorkbenchState())
        state = WorkbenchRules.toggle(state)
        state = WorkbenchRules.toggle(state)
        #expect(state.isOpen)
        #expect(state.panes[0].tabs == [term1])
        #expect(!WorkbenchRules.showsDetails(state))
    }

    @Test func detailsShownNeedsOpenPanelAndSelectedDetails() {
        var state = WorkbenchRules.open(.details, in: WorkbenchState())
        #expect(WorkbenchRules.showsDetails(state))
        state = WorkbenchRules.open(browser, in: state)
        #expect(!WorkbenchRules.showsDetails(state))
        state = WorkbenchRules.select(.details, in: state)
        #expect(WorkbenchRules.showsDetails(state))
        state.isOpen = false
        #expect(!WorkbenchRules.showsDetails(state))
    }

    // MARK: tab presentation

    @MainActor @Test func routerKeepsTheWorkbenchOfEachAgentApart() {
        let router = Router()
        #expect(!router.workbenchState(for: "forge").isOpen)
        router.updateWorkbench(for: "forge") { WorkbenchRules.open(term1, in: $0) }
        router.updateWorkbench(for: "scout") { WorkbenchRules.open(browser, in: $0) }
        #expect(router.workbenchState(for: "forge").allTabs == [term1])
        #expect(router.workbenchState(for: "scout").allTabs == [browser])
        #expect(router.workbenchState(for: "nobody").allTabs.isEmpty)
    }

    @Test func browserToolsAreRecognisedByExactNames() {
        #expect(WorkbenchRules.isBrowserTool("browser_click"))
        #expect(WorkbenchRules.isBrowserTool("browser_snapshot"))
        #expect(WorkbenchRules.isBrowserTool("mcp__bandito__browser_open"))
        #expect(!WorkbenchRules.isBrowserTool("Browser.getVersion"))
        #expect(!WorkbenchRules.isBrowserTool("browser.agent.click"))
        #expect(!WorkbenchRules.isBrowserTool("Bash"))
    }

    @Test func browserChipShowsWhileBrowserToolRunsUnlessTheBrowserIsOnShow() {
        let closed = WorkbenchState()
        #expect(WorkbenchRules.showsBrowserChip(state: closed, runningTools: ["browser_open"]))
        #expect(!WorkbenchRules.showsBrowserChip(state: closed, runningTools: ["Bash"]))
        #expect(!WorkbenchRules.showsBrowserChip(state: closed, runningTools: []))
        // A tab that exists but is not on show (the panel closed, or another tab selected) still gets the chip.
        let withTab = WorkbenchRules.open(.browser, in: closed)
        let otherTabOnShow = WorkbenchRules.select(.details, in: WorkbenchRules.open(.browser, in: WorkbenchRules.open(.details, in: closed)))
        #expect(WorkbenchRules.showsBrowserChip(state: otherTabOnShow, runningTools: ["browser_open"]))
        var closedPanel = withTab
        closedPanel.isOpen = false
        #expect(WorkbenchRules.showsBrowserChip(state: closedPanel, runningTools: ["browser_open"]))
        // The browser on show in an open panel: no chip.
        #expect(!WorkbenchRules.showsBrowserChip(state: withTab, runningTools: ["browser_open"]))
    }

    @Test func runningToolsIgnoreCallsOlderThanTenMinutesWithoutAResult() {
        let now: Int64 = 10_000_000
        let rows = [
            ToolRow(callId: "1", tool: "browser_open", title: "", ok: nil, output: nil, startedAt: now - 1_000),
            ToolRow(callId: "2", tool: "browser_click", title: "", ok: nil, output: nil,
                    startedAt: now - WorkbenchRules.runningToolWindowMs - 1),
            ToolRow(callId: "3", tool: "Bash", title: "", ok: true, output: nil, startedAt: now - 5),
            ToolRow(callId: "4", tool: "browser_snapshot", title: "", ok: nil, output: nil, startedAt: nil),
        ]
        #expect(WorkbenchRules.runningToolNames(rows, now: now) == ["browser_open", "browser_snapshot"])
    }

    @MainActor @Test func shortcutsActOnTheFocusedPaneOfTheSelectedAgent() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.showInWorkbench(term1, agentID: "forge")
        router.toggleWorkbenchSplit(agentID: "forge")
        #expect(router.workbenchState(for: "forge").isSplit)
        #expect(router.workbenchState(for: "forge").focusedPane == 1)
        router.showInWorkbench(browser, agentID: "forge")
        router.focusWorkbenchPane(0, agentID: "forge")
        router.selectFocusedWorkbenchTab(at: 0)
        #expect(router.workbenchState(for: "forge").panes[0].selected == term1)
        router.selectFocusedWorkbenchTab(at: 5)
        #expect(router.workbenchState(for: "forge").panes[0].selected == term1)
        // Closing the only tab of the top pane empties it; the panes join into one.
        router.closeFocusedWorkbenchTab()
        #expect(!router.workbenchState(for: "forge").isSplit)
        #expect(router.workbenchState(for: "forge").allTabs == [.details, browser])
        router.toggleWorkbenchSplit(agentID: "forge")
        #expect(router.workbenchState(for: "forge").isSplit)
    }

    @MainActor @Test func openingATerminalIsNotRequestedTwice() {
        let router = Router()
        #expect(router.beginOpeningTerminal(agentID: "forge"))
        #expect(!router.beginOpeningTerminal(agentID: "forge"))
        #expect(router.beginOpeningTerminal(agentID: "scout"))
        router.endOpeningTerminal(agentID: "forge")
        #expect(router.beginOpeningTerminal(agentID: "forge"))
    }

    @MainActor @Test func workbenchStateBelongsToTheServerInFront() {
        let router = Router()
        router.frontServerID = "server-a"
        router.showInWorkbench(term1, agentID: "forge")
        router.frontServerID = "server-b"
        #expect(router.workbenchState(for: "forge").allTabs.isEmpty)
        router.frontServerID = "server-a"
        #expect(router.workbenchState(for: "forge").allTabs == [term1])
        #expect(Router.workbenchKey(server: "server-a", agentID: "forge") != Router.workbenchKey(server: "server-b", agentID: "forge"))
    }

    @MainActor @Test func forgettingAnAgentDropsItsWorkbenchAndNotice() {
        let router = Router()
        router.showInWorkbench(term1, agentID: "forge")
        router.setWorkbenchNotice(UserFacingMessage(text: "failed"), for: "forge")
        #expect(router.beginOpeningTerminal(agentID: "forge"))
        router.forgetWorkbench(agentID: "forge")
        #expect(router.workbenchState(for: "forge").allTabs.isEmpty)
        #expect(router.workbenchNotice(for: "forge") == nil)
        #expect(router.beginOpeningTerminal(agentID: "forge"))
    }

    @MainActor @Test func shortcutsActOnTheAgentOnScreenNotTheSelectedOne() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.shownAgentID = "scout"
        router.toggleDetails()
        #expect(router.workbenchState(for: "scout").isOpen)
        #expect(!router.workbenchState(for: "forge").isOpen)
        #expect(router.inspectorOpen)
        router.toggleDetails()
        #expect(!router.workbenchState(for: "scout").isOpen)
    }

    @Test func closingTheLastTabOfTheTopPaneJoinsThePanes() {
        var state = WorkbenchRules.split(WorkbenchRules.open(term1, in: WorkbenchState()))
        state = WorkbenchRules.open(browser, in: state)
        state = WorkbenchRules.select(term1, in: state)
        state = WorkbenchRules.close(term1, in: state)
        #expect(state.panes.count == 1)
        #expect(state.panes[0].tabs == [.details, browser])
        #expect(state.focusedPane == 0)
        #expect(state.isOpen)
    }

    @Test func focusedPaneIsNilForAnIndexOutOfRange() {
        var state = WorkbenchRules.open(term1, in: WorkbenchState())
        #expect(WorkbenchRules.focusedPane(of: state)?.tabs == [term1])
        state.focusedPane = 3
        #expect(WorkbenchRules.focusedPane(of: state) == nil)
    }

    @Test func selectingAnUnknownTabChangesNothing() {
        let state = WorkbenchRules.open(term1, in: WorkbenchState())
        #expect(WorkbenchRules.select(browser, in: state) == state)
    }

    @Test func fileTabTitleIsItsFileName() {
        #expect(notes.fileName == "today.md")
        #expect(term1.fileName == nil)
    }

    @Test func everyTabHasASymbol() {
        let tabs: [WorkbenchTab] = [.details, term1, browser, notes, .changes]
        for tab in tabs {
            #expect(!tab.systemImage.isEmpty)
        }
    }

    // MARK: layout

    @Test func widthIsKeptBetweenMinimumAndSeventyPercentOfWindow() {
        #expect(WorkbenchLayout.clampWidth(100, windowWidth: 1600) == 320)
        #expect(WorkbenchLayout.clampWidth(900, windowWidth: 1600) == 900)
        #expect(WorkbenchLayout.clampWidth(900, windowWidth: 1000) == 700)
        #expect(WorkbenchLayout.clampWidth(460, windowWidth: 900) == 460)
    }

    /// The panel gives way to the chat first: it narrows to 320 pt, and covers the chat only when even that leaves the
    /// chat under 420 pt.
    @Test func panelNarrowsBeforeItCoversTheChat() {
        #expect(WorkbenchLayout.fittedWidth(stored: 460, modeWidth: 1240) == 460)
        #expect(WorkbenchLayout.fittedWidth(stored: 460, modeWidth: 800) == 380)
        #expect(!WorkbenchLayout.coversChat(modeWidth: 800, panelWidth: 380))
        // 740 pt: the panel at its 320 pt minimum leaves the chat exactly 420 pt, so nothing is covered.
        #expect(WorkbenchLayout.fittedWidth(stored: 460, modeWidth: 740) == 320)
        #expect(!WorkbenchLayout.coversChat(modeWidth: 740, panelWidth: 320))
        #expect(WorkbenchLayout.fittedWidth(stored: 460, modeWidth: 700) == 320)
        #expect(WorkbenchLayout.coversChat(modeWidth: 700, panelWidth: 320))
    }

    /// The panel covers the chat only when beside it the chat would be narrower than 420 pt.
    @Test func panelCoversTheChatOnlyWhenTheChatWouldBeNarrowerThan420() {
        // Beside the chat there is room: no cover, even below 1100 pt.
        #expect(!WorkbenchLayout.coversChat(modeWidth: 1000, panelWidth: 460))
        #expect(!WorkbenchLayout.coversChat(modeWidth: 900, panelWidth: 460))
        // Exactly 420 pt left for the chat is enough.
        #expect(!WorkbenchLayout.coversChat(modeWidth: 880, panelWidth: 460))
        // One point less, and the panel lies over the chat.
        #expect(WorkbenchLayout.coversChat(modeWidth: 879, panelWidth: 460))
        #expect(WorkbenchLayout.coversChat(modeWidth: 900, panelWidth: 500))
        #expect(WorkbenchLayout.coversChat(modeWidth: 1100, panelWidth: 700))
    }

    /// The resize edge: no movement writes nothing; a drag works from the chosen width and stays in bounds.
    @Test func resizeDragStartsFromTheChosenWidth() {
        #expect(WorkbenchLayout.draggedWidth(stored: 460, translation: 0, windowWidth: 1000) == nil)
        // Dragging left by 40 pt makes the panel 40 pt wider than the chosen width.
        #expect(WorkbenchLayout.draggedWidth(stored: 460, translation: -40, windowWidth: 1000) == 500)
        #expect(WorkbenchLayout.draggedWidth(stored: 460, translation: 30, windowWidth: 1000) == 430)
        #expect(WorkbenchLayout.draggedWidth(stored: 460, translation: -2000, windowWidth: 1000) == 700)
    }

    /// Narrow panel: the inactive tabs show icons, the active one keeps its name; the changes header keeps only the avatar.
    @Test func narrowPanelKeepsTheActiveTabNameAndDropsTheOthers() {
        #expect(WorkbenchLayout.showsTabTitle(selected: false, panelWidth: 359) == false)
        #expect(WorkbenchLayout.showsTabTitle(selected: false, panelWidth: 360))
        #expect(WorkbenchLayout.showsTabTitle(selected: true, panelWidth: 320))
        #expect(WorkbenchLayout.showsAgentTitle(panelWidth: 320) == false)
        #expect(WorkbenchLayout.showsAgentTitle(panelWidth: 360))
    }

    @Test func splitShareIsKeptBetweenTwentyAndEightyPercent() {
        #expect(WorkbenchLayout.clampSplit(0.05) == 0.2)
        #expect(WorkbenchLayout.clampSplit(0.95) == 0.8)
        #expect(WorkbenchLayout.clampSplit(0.5) == 0.5)
    }
}

@Suite struct WorkbenchPaneLookupTests {
    @Test func aPanePastTheEndReadsAsEmpty() {
        let state = WorkbenchRules.open(.details, in: WorkbenchState())
        #expect(state.panes.count == 1)
        #expect(WorkbenchRules.pane(1, of: state) == WorkbenchPane())
        #expect(WorkbenchRules.pane(0, of: state).tabs == [.details])
    }
}
