import Testing

@testable import BanditoUI

/// The folder history behind `<` `>` in Files: visits, steps back and forward, and the limit.
@Suite struct FolderHistoryTests {
    @Test func emptyHistoryHasNothingToStepTo() {
        var history = FolderHistory()
        #expect(history.current == nil)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.back() == nil)
        #expect(history.forward() == nil)
    }

    @Test func firstVisitBecomesCurrentWithNothingBehind() {
        var history = FolderHistory()
        history.visit("/a")
        #expect(history.current == "/a")
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func visitingMovesForwardInHistory() {
        var history = FolderHistory()
        history.visit("/a")
        history.visit("/a/b")
        #expect(history.current == "/a/b")
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func backReturnsToPreviousFolderAndForwardReturnsAgain() {
        var history = FolderHistory()
        history.visit("/a")
        history.visit("/a/b")
        #expect(history.back() == "/a")
        #expect(history.current == "/a")
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
        #expect(history.forward() == "/a/b")
        #expect(history.current == "/a/b")
        #expect(!history.canGoForward)
    }

    @Test func stepsDoNotChangeTheListOfVisits() {
        var history = FolderHistory()
        history.visit("/a")
        history.visit("/b")
        history.visit("/c")
        _ = history.back()
        _ = history.back()
        _ = history.forward()
        #expect(history.paths == ["/a", "/b", "/c"])
        #expect(history.current == "/b")
    }

    @Test func visitAfterBackDropsTheForwardPart() {
        var history = FolderHistory()
        history.visit("/a")
        history.visit("/b")
        history.visit("/c")
        _ = history.back()
        _ = history.back()
        history.visit("/d")
        #expect(history.paths == ["/a", "/d"])
        #expect(history.current == "/d")
        #expect(!history.canGoForward)
        #expect(history.back() == "/a")
    }

    @Test func visitingTheCurrentFolderAgainDoesNotDuplicate() {
        var history = FolderHistory()
        history.visit("/a")
        history.visit("/a")
        #expect(history.paths == ["/a"])
        #expect(!history.canGoBack)
    }

    @Test func visitingTheCurrentFolderAfterBackKeepsForwardPart() {
        // The browser reports the folder it arrived in after a step; that must not count as a new visit.
        var history = FolderHistory()
        history.visit("/a")
        history.visit("/b")
        _ = history.back()
        history.visit("/a")
        #expect(history.paths == ["/a", "/b"])
        #expect(history.canGoForward)
    }

    @Test func limitKeepsTheNewestHundredFolders() {
        var history = FolderHistory()
        for index in 0..<150 {
            history.visit("/f\(index)")
        }
        #expect(history.paths.count == FolderHistory.limit)
        #expect(FolderHistory.limit == 100)
        #expect(history.paths.first == "/f50")
        #expect(history.current == "/f149")
        #expect(history.back() == "/f148")
    }
}
