import Testing

@testable import BanditoUI

/// The details panel of the Files browser: which flag shows it, and what its close button turns off. And the
/// viewer's empty-file hint.
@Suite struct FilesPanelAndViewerTests {
    @Test func dockedPanelFollowsThePreviewFlag() {
        #expect(FileBrowserLayout.panelShown(docked: true, previewVisible: true, overlayOpen: false))
        #expect(!FileBrowserLayout.panelShown(docked: true, previewVisible: false, overlayOpen: true))
    }

    @Test func overPanelFollowsTheOverlayFlag() {
        #expect(FileBrowserLayout.panelShown(docked: false, previewVisible: false, overlayOpen: true))
        #expect(!FileBrowserLayout.panelShown(docked: false, previewVisible: true, overlayOpen: false))
    }

    @Test func closingDockedPanelHidesItAndKeepsTheOverlayFlag() {
        let next = FileBrowserLayout.closed(docked: true, previewVisible: true, overlayOpen: true)
        #expect(next.previewVisible == false)
        #expect(next.overlayOpen == true)
    }

    @Test func closingOverPanelHidesItAndKeepsThePreviewFlag() {
        let next = FileBrowserLayout.closed(docked: false, previewVisible: true, overlayOpen: true)
        #expect(next.overlayOpen == false)
        #expect(next.previewVisible == true)
    }

    @Test func emptyFileShowsTheHint() {
        #expect(FileViewerRules.showsEmptyHint(text: ""))
    }

    @Test func whitespaceIsTextNotEmpty() {
        #expect(!FileViewerRules.showsEmptyHint(text: "\n"))
        #expect(!FileViewerRules.showsEmptyHint(text: " "))
    }
}
