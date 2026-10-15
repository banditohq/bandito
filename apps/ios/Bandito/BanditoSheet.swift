import BanditoDesign
import SwiftUI

extension View {
    /// The one look of every sheet of the iPhone app: the warm ground behind the whole sheet. Without it the system's
    /// sheet background shows at the edges (grey strips beside a content that is inset from them). Put it on the content
    /// of a `.sheet`, never on a view inside the content.
    func banditoSheet() -> some View {
        presentationBackground(Color.Bandito.bg)
    }
}
