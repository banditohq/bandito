import SwiftUI

/// The first-run tour is gone. The two anchors left are marks in the chat's files (the thread rows and the composer);
/// they do nothing and go when those files are next touched.
enum TourAnchor { case composer, approvals }

extension View {
    func tourAnchor(_ anchor: TourAnchor) -> some View { self }
}
