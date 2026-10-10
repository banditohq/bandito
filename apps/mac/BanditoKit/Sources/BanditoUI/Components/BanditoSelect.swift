import AppKit
import BanditoDesign
import BanditoL10n
import SwiftUI

/// One choice of a `BanditoSelect`.
public struct SelectOption<Value: Hashable>: Identifiable {
    public var value: Value
    public var title: String
    /// A short line: under the title in the panel, beside the title in the field.
    public var subtitle: String?
    /// An SF Symbol name, shown before the title.
    public var icon: String?
    /// The colour of the icon. Nil uses the secondary text colour.
    public var tint: Color?
    /// A disabled option is shown dimmed and skipped by the keyboard.
    public var isEnabled: Bool
    /// A tooltip for the row. Nil or empty gives none.
    public var help: String?
    /// The title is an identifier (a model id), shown in monospace.
    public var monospaced: Bool

    public var id: Value { value }

    public init(
        value: Value, title: String, subtitle: String? = nil, icon: String? = nil, tint: Color? = nil,
        isEnabled: Bool = true, help: String? = nil, monospaced: Bool = false
    ) {
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.isEnabled = isEnabled
        self.help = help
        self.monospaced = monospaced
    }
}

/// A group of choices with an optional heading (shown with `SectionLabel`).
public struct SelectSection<Value: Hashable> {
    public var title: String?
    public var options: [SelectOption<Value>]

    public init(title: String? = nil, options: [SelectOption<Value>]) {
        self.title = title
        self.options = options
    }
}

/// The standard look of a select field: the chosen option's icon, title and subtitle, and the chevron. A field with
/// no chosen option shows the placeholder.
public struct SelectFieldView: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let tint: Color?
    let isPlaceholder: Bool
    let monospaced: Bool

    public init<Value: Hashable>(option: SelectOption<Value>?, placeholder: String) {
        title = option?.title ?? placeholder
        subtitle = option?.subtitle
        icon = option?.icon
        tint = option?.tint
        isPlaceholder = option == nil
        monospaced = option?.monospaced ?? false
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? Color.Bandito.text2)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(BanditoFont.font(size: 13.5, weight: 400, mono: monospaced))
                .foregroundStyle(isPlaceholder ? Color.Bandito.text3 : Color.Bandito.text)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10))
                .foregroundStyle(Color.Bandito.text3)
                .accessibilityHidden(true)
        }
        .modifier(FieldBox())
    }
}

/// A field that opens a panel of choices. The whole field is the button: a click anywhere on it opens the panel. The
/// panel sits under the field, as wide as the field (280 to 520 points), with search above eight options, keyboard
/// movement (↑ ↓ choose, Esc closes), and a checkmark on the chosen option only. A `footer` sits under the options and
/// gets a `close` action, for an item that does something else (such as "Other model…").
public struct BanditoSelect<Value: Hashable, Field: View, Footer: View>: View {
    private let selection: Binding<Value>
    private let sections: [SelectSection<Value>]
    private let label: String
    private let placeholder: String
    private let field: (SelectOption<Value>?) -> Field
    private let footer: (@escaping () -> Void) -> Footer

    @State private var isOpen = false
    @State private var fieldWidth: CGFloat = 0

    /// - Parameters:
    ///   - selection: The value of the chosen option.
    ///   - sections: The options, in sections. A value no option has shows the placeholder.
    ///   - label: What the field is, for VoiceOver ("Memory", "Model").
    ///   - placeholder: The field's text when no option is chosen.
    ///   - field: The field's look, given the chosen option (nil when there is none).
    ///   - footer: Shown under the options. It is given the action that closes the panel.
    public init(
        selection: Binding<Value>, sections: [SelectSection<Value>], label: String, placeholder: String,
        field: @escaping (SelectOption<Value>?) -> Field,
        footer: @escaping (@escaping () -> Void) -> Footer
    ) {
        self.selection = selection
        self.sections = sections
        self.label = label
        self.placeholder = placeholder
        self.field = field
        self.footer = footer
    }

    public var body: some View {
        let chosen = sections.flatMap(\.options).first { $0.value == selection.wrappedValue }
        Button {
            isOpen = true
        } label: {
            field(chosen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SelectFieldWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(SelectFieldWidthKey.self) { fieldWidth = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(chosen?.title ?? placeholder)
        .popover(isPresented: $isOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            SelectPanel(
                selection: selection, sections: sections, footer: footer { isOpen = false },
                close: { isOpen = false }
            )
            .frame(width: SelectFilter.panelWidth(fieldWidth: fieldWidth))
        }
    }
}

extension BanditoSelect where Field == SelectFieldView, Footer == EmptyView {
    /// A select with the standard field and no footer.
    public init(
        selection: Binding<Value>, sections: [SelectSection<Value>], label: String, placeholder: String
    ) {
        self.init(
            selection: selection, sections: sections, label: label, placeholder: placeholder,
            field: { SelectFieldView(option: $0, placeholder: placeholder) },
            footer: { _ in EmptyView() })
    }
}

extension BanditoSelect where Field == SelectFieldView {
    /// A select with the standard field and a footer.
    public init(
        selection: Binding<Value>, sections: [SelectSection<Value>], label: String, placeholder: String,
        footer: @escaping (@escaping () -> Void) -> Footer
    ) {
        self.init(
            selection: selection, sections: sections, label: label, placeholder: placeholder,
            field: { SelectFieldView(option: $0, placeholder: placeholder) }, footer: footer)
    }
}

/// The field's width, reported up so the panel can match it.
private struct SelectFieldWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The panel: search, the sections, the footer. It is built only while the popover is open.
private struct SelectPanel<Value: Hashable, Footer: View>: View {
    let selection: Binding<Value>
    let sections: [SelectSection<Value>]
    let footer: Footer
    let close: () -> Void

    @State private var model = SelectPanelModel<Value>()
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Computed once per render: the search, the rows the keys act on, and the search field's presence.
        let groups = SelectFilter.groups(sections, query: model.query)
        let rows = groups.flatMap(\.options)
        let showsSearch = SelectFilter.showsSearch(optionCount: sections.reduce(0) { $0 + $1.options.count })
        let selected = rows.firstIndex { $0.value == selection.wrappedValue }
        model.rows = rows
        model.choose = { value in
            selection.wrappedValue = value
            close()
        }
        model.close = close

        return VStack(alignment: .leading, spacing: 0) {
            if showsSearch {
                // The same search field as Settings → Keys: a lens, the text, the same surface and border.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.Bandito.text3)
                        .accessibilityHidden(true)
                    TextField(L10n.Select.search, text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .focused($searchFocused)
                        .accessibilityLabel(L10n.Select.search)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.Bandito.text.opacity(0.08)))
                .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // The top of the list, where a new search starts.
                        Color.clear
                            .frame(height: 0)
                            .id(SelectPanelModel<Value>.topMarker)
                        if rows.isEmpty {
                            Text(L10n.Select.noResults)
                                .font(BanditoFont.font(size: 12.5, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 14)
                        }
                        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                            let base = groups.prefix(groupIndex).reduce(0) { $0 + $1.options.count }
                            if let title = group.title {
                                SectionLabel(title)
                                    .padding(.horizontal, 10)
                                    .padding(.top, groupIndex == 0 ? 2 : 10)
                                    .padding(.bottom, 2)
                            }
                            ForEach(Array(group.options.enumerated()), id: \.offset) { offset, option in
                                optionRow(option, index: base + offset, selected: selected == base + offset)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onAppear {
                    // After the first layout, so the row exists to scroll to: the selected one, or the first.
                    DispatchQueue.main.async {
                        if let index = model.highlight {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
                .onChange(of: model.keyboardMoves) { _, _ in
                    if let index = model.highlight {
                        proxy.scrollTo(index)
                    }
                }
                .onChange(of: model.query) { _, _ in
                    proxy.scrollTo(SelectPanelModel<Value>.topMarker, anchor: .top)
                }
            }
            footer
        }
        // The panel is as tall as its content, up to the list's cap: it stays under the field.
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(PanelWindowProbe { window in model.window = window })
        .onAppear {
            model.start()
            model.highlight = SelectHighlight.initial(enabled: model.enabled, selectedIndex: selected)
            searchFocused = showsSearch
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.query) { _, _ in
            model.highlight = SelectHighlight.initial(enabled: model.enabled, selectedIndex: nil)
        }
        .banditoAnimation(BanditoMotion.ease, value: model.query)
    }

    private func optionRow(_ option: SelectOption<Value>, index: Int, selected: Bool) -> some View {
        let highlighted = model.highlight == index && option.isEnabled
        return Button {
            model.choose(option.value)
        } label: {
            HStack(spacing: 10) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(option.tint ?? Color.Bandito.text2)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(BanditoFont.font(size: 13, weight: 500, mono: option.monospaced))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    if let subtitle = option.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(BanditoFont.font(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.Bandito.signal)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted ? Color.Bandito.text.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .opacity(option.isEnabled ? 1 : 0.45)
        }
        .banditoButton(.row(cornerRadius: 9))
        .disabled(!option.isEnabled)
        .optionalHelp(option.help)
        // Only a real pointer move takes the highlight. A list that scrolls under a still pointer (the keys, or a
        // trackpad flick) passes rows under it, and those must not change the highlight.
        .onContinuousHover { phase in
            guard case .active = phase, option.isEnabled else { return }
            let pointer = NSEvent.mouseLocation
            guard pointer != model.pointer else { return }
            model.pointer = pointer
            model.highlight = index
        }
        .banditoAnimation(BanditoMotion.ease, value: highlighted)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(index)
    }
}
