import BanditoDesign
import SwiftUI

/// The square icon of a settings row or navigation item: an SF Symbol, white, on a colored fill (24 pt, as in System
/// Settings on macOS).
struct SettingsBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: 24, height: 24)
            .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A group of settings: a section label over a card. The rows inside are laid out by `SettingsRow`.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SectionLabel(title)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .banditoCard()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Common frame of a settings section: title, a short line under it, then the content. Groups are 16 pt apart.
struct SettingsPage<Content: View>: View {
    var title: String
    var intro: String?
    @ViewBuilder var content: Content

    var body: some View {
        // The whole page scrolls, so nothing is cut off at the smallest window size.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(BanditoFont.font(size: 22, weight: 650))
                        .foregroundStyle(Color.Bandito.text)
                    if let intro {
                        Text(intro)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 22)
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
    }
}

/// One setting: a title and hint on the left, the control on the right. When the control leaves no room for the
/// text, the control goes under the text (full width), so a title never breaks letter by letter.
struct SettingsRow<Control: View>: View {
    var title: String
    var hint: String?
    /// The icon plate at the left of the row, when the row has one.
    var icon: SettingsIcon?
    /// A switch stays at the right whatever the text length: the text wraps beside it. Wide controls (buttons,
    /// selects) go under a long text instead.
    var keepsControlBeside = false
    @ViewBuilder var control: Control

    var body: some View {
        Group {
            if keepsControlBeside {
                HStack(alignment: .center, spacing: 16) {
                    leading
                    control.fixedSize()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        leading
                        Spacer(minLength: 12)
                        control
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        leading
                        HStack(spacing: 8) {
                            control
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Every row is at least 44 pt high, as in System Settings, so a short row does not look cramped.
        .frame(minHeight: 44)
    }

    /// The icon (when there is one) and the text, side by side.
    private var leading: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                SettingsBadge(symbol: icon.symbol, tint: icon.tint)
            }
            textBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The symbol and fill of a row's icon plate.
struct SettingsIcon {
    let symbol: String
    let tint: Color
}
