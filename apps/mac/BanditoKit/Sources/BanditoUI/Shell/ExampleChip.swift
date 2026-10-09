import BanditoL10n
import SwiftUI

/// Marks sample data ("Example") wherever it stands in for a real value.
public struct ExampleChip: View {
    public init() {}

    public var body: some View {
        Chip(text: L10n.Demo.badge)
    }
}
