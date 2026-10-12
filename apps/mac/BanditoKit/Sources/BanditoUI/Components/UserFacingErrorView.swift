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
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.canRetry, let onRetry {
                Button(L10n.Banner.retry, action: onRetry)
                    .banditoButton(.quiet())
            }
            if let technical = message.technical {
                TechnicalDetailsRow(technical: technical)
            }
        }
    }
}

/// "Подробнее": one row across the whole width of the sentence, so the whole line is the target and not only the small
/// label. A click anywhere on the row opens or closes the technical text, which can be copied.
private struct TechnicalDetailsRow: View {
    let technical: String
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.Failure.details)
                        .font(BanditoFont.text(size: 12, weight: 500))
                    Spacer(minLength: 8)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.Bandito.text2)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .banditoButton(.row())
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text(technical)
                        .font(BanditoFont.mono(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.Failure.copy) { SystemActions.copy(technical) }
                        .banditoButton(.quiet())
                }
                .padding(.horizontal, 8)
            }
        }
    }
}
