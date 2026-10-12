import SwiftUI

/// The bottom row of a sheet or dialog. The buttons sit in one row, pushed to the trailing edge; when they do not fit
/// the width on offer (a long translation, a narrow window) they stack in a column at the trailing edge instead of
/// running past the edge. Put buttons only in `content`; a status text goes beside the row, not inside it.
///
/// Next to a text in an `HStack`, pass `hugging: true`: the row then takes only the width of its buttons, so the text
/// keeps the rest. Without it the row fills the width it is offered, which would squeeze such a text into a column.
struct ActionRow<Content: View>: View {
    var hugging = false
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content
            }
            VStack(alignment: .trailing, spacing: 8) {
                content
            }
        }
        // ViewThatFits takes all the height on offer; the row is only as tall as its buttons.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: hugging ? nil : .infinity, alignment: .trailing)
    }
}
