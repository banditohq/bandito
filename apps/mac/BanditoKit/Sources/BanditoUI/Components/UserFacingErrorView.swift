import BanditoDesign
import BanditoL10n
import SwiftUI

/// A failure in the interface: the sentence from `UserFacingError`, "Повторить" when the server did not answer,
/// and "Подробнее" with the technical text (monospaced, copyable) when the sentence cannot say what happened.
struct UserFacingErrorView: View {
    let message: UserFacingMessage
    /// Runs "Повторить". Without it the retry button is not shown, even for a dead connection.
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.canRetry, let onRetry {
                Button(L10n.Banner.retry, action: onRetry)
                    .buttonStyle(QuietButtonStyle())
            }
            if let technical = message.technical {
                DisclosureGroup(L10n.Failure.details) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(technical)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.Bandito.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.Failure.copy) { SystemActions.copy(technical) }
                            .buttonStyle(QuietButtonStyle())
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            }
        }
    }
}
