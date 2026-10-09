import BanditoDesign
import SwiftUI

/// Segmented control: a tinted track with one raised segment that slides to the selected option.
public struct SegmentedPicker<T: Hashable>: View {
    @Binding private var selection: T
    private let options: [(T, String)]
    @Namespace private var namespace

    /// - Parameters:
    ///   - selection: The selected option's value.
    ///   - options: Pairs of value and visible title, in display order.
    public init(selection: Binding<T>, options: [(T, String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(value: options[index].0, title: options[index].1)
            }
        }
        .padding(3)
        .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .banditoAnimation(BanditoMotion.ease, value: selection)
    }

    private func segment(value: T, title: String) -> some View {
        let isSelected = value == selection
        return Button {
            selection = value
        } label: {
            Text(title)
                .font(BanditoFont.font(size: 12.5, weight: isSelected ? 600 : 500))
                .foregroundStyle(isSelected ? Color.Bandito.text : Color.Bandito.text3)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.Bandito.surface3)
                            .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
    }
}
