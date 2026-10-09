import BanditoDesign
import SwiftUI

/// Compact switch, 36×21: signal track with a white knob when on, cream hairline track with a
/// muted knob when off. The whole row (label and switch) toggles.
public struct BanditoToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Color.Bandito.signalFill : Color.Bandito.text.opacity(0.14))
                    Circle()
                        .fill(configuration.isOn ? Color.white : Color.Bandito.text2)
                        .frame(width: 17, height: 17)
                        .padding(2)
                }
                .frame(width: 36, height: 21)
                .animation(BanditoMotion.ease, value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
    }
}
