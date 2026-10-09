import BanditoDesign
import BanditoKit
import SwiftUI

/// The app's root: the main window. Onboarding will go in front of it once it exists.
public struct RootView: View {
    public init() {}

    public var body: some View {
        MainWindow()
            .background(Color.Bandito.bg)
    }
}
