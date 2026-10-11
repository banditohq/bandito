import SwiftUI

/// The bottom row of a sheet or dialog. The buttons sit in one row, pushed to the trailing edge; when they do not fit
/// the width on offer (a long translation, a narrow window) they stack in a column at the trailing edge instead of
/// running past the edge. Put buttons only in `content`; a status text goes beside the row, not inside it.
struct ActionRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                content
            }
            VStack(alignment: .trailing, spacing: 8) {
                content
            }
        }
    }
}
