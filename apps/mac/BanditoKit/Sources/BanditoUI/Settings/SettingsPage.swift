import BanditoDesign
import SwiftUI

/// Common frame of a settings section: title, an optional intro line, then the content.
struct SettingsPage<Content: View>: View {
    var title: String
    var intro: String?
    @ViewBuilder var content: Content

    var body: some View {
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One setting: a title and hint on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    var title: String
    var hint: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
