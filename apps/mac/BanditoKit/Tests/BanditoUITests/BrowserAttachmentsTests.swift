import Testing

@testable import BanditoUI

/// The browser of a server is one model shared by Browser mode and the workbench tab. Each view attaches on appear and
/// detaches on disappear. The model polls while any view is attached: a view that leaves while another one has taken
/// over must not stop the polling for the view that stays.
@Suite struct BrowserAttachmentsTests {
    @Test func startsDetached() {
        #expect(!BrowserAttachments().isAttached)
    }

    @Test func onlyTheFirstAttachStartsPolling() {
        var attachments = BrowserAttachments()
        let first = attachments.attach()
        let second = attachments.attach()
        #expect(first, "the first view starts the polling")
        #expect(!second, "a second view finds it running")
        #expect(attachments.isAttached)
    }

    @Test func lastDetachStopsPolling() {
        var attachments = BrowserAttachments()
        _ = attachments.attach()
        _ = attachments.attach()
        let firstDetach = attachments.detach()
        #expect(!firstDetach, "one view is still attached")
        #expect(attachments.isAttached)
        let lastDetach = attachments.detach()
        #expect(lastDetach, "the last view stops it")
        #expect(!attachments.isAttached)
    }

    /// Switching from the workbench tab to Browser mode: the new view attaches before the old one detaches.
    @Test func handOffKeepsPollingForTheViewThatStays() {
        var attachments = BrowserAttachments()
        _ = attachments.attach()
        _ = attachments.attach()
        _ = attachments.detach()
        #expect(attachments.isAttached, "the browser mode still shows the page and must keep polling")
    }

    @Test func extraDetachDoesNotGoNegative() {
        var attachments = BrowserAttachments()
        let stray = attachments.detach()
        #expect(!stray)
        #expect(!attachments.isAttached)
        let next = attachments.attach()
        #expect(next, "the next view still starts it")
    }
}
