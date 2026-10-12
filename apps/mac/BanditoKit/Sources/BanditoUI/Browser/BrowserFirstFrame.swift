import Foundation

/// When a page connection needs one still picture of the page. A static page sends no screencast frame after
/// `Page.startScreencast` (the screencast sends frames only when the page repaints), so the first picture would never
/// come. The still (`Page.captureScreenshot`) fills that gap; a screencast frame that does come makes it unneeded.
enum BrowserFirstFrameRule {
    /// How long a screencast start may go without a frame before a still is asked.
    static let screencastWait: Duration = .milliseconds(1500)

    /// - Parameters:
    ///   - sawFrame: a screencast frame came for this connection since its screencast started.
    ///   - isCurrentClient: the connection is still the one shown; a connection that was replaced or closed asks nothing.
    static func needsStill(sawFrame: Bool, isCurrentClient: Bool) -> Bool {
        isCurrentClient && !sawFrame
    }
}
