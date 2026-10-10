import SwiftUI

extension View {
    /// Attaches a tooltip only when there is text for it. `.help("")` would still attach an empty tooltip.
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}
