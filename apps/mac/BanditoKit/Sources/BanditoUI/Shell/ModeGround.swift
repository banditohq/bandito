import BanditoDesign
import SwiftUI

extension View {
    /// A mode's flat ground: the background colour under the whole mode, the title strip above it included, taking no
    /// clicks (the title band behind the mode gets the empty space: a double-click zooms the window).
    ///
    /// The ground must reach under the title strip: a ground that stopped at the safe area let the main area's backdrop
    /// (its warm glow hanging from the top edge) show through the strip and through the gap beside the agent's panel.
    func modeGround() -> some View {
        background { Color.Bandito.bg.ignoresSafeArea().allowsHitTesting(false) }
    }
}
