import BanditoDesign
import SwiftUI

/// Common frame of a settings section: title, an optional intro line, then the content.
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
                        .font(.system(size: 22, weight: .semibold))
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
                content
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
    @ViewBuilder var control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                textBlock
                Spacer(minLength: 12)
                control
            }
            VStack(alignment: .leading, spacing: 10) {
                textBlock
                HStack(spacing: 8) {
                    control
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
