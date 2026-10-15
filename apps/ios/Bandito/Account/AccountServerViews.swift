import BanditoDesign
import BanditoL10n
import SwiftUI

/// One server of the account that this iPhone does not hold yet: its name and, in grey under it, where it stands.
struct AccountServerLine: View {
    let row: AccountServerRow

    var body: some View {
        HStack(spacing: BanditoSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                Text(row.note.text)
                    .font(BanditoFont.text(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BanditoSpace.s2)
            if row.note.isWorking {
                ProgressView().tint(Color.Bandito.text2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Crew tab while no server is connected yet but the account is ready: the servers of the account and where each
/// stands, instead of the welcome. A button still connects one by hand.
struct AccountServersNotice: View {
    let rows: [AccountServerRow]
    let fetching: Bool
    let onConnect: () -> Void

    private var working: Bool { fetching || rows.contains { $0.note.isWorking } }

    var body: some View {
        VStack(spacing: BanditoSpace.s5) {
            Spacer()
            VStack(spacing: BanditoSpace.s3) {
                if working {
                    ProgressView().tint(Color.Bandito.text2)
                }
                Text(working ? L10n.Ios.AccountServers.fetching : L10n.Ios.AccountServers.title)
                    .font(BanditoFont.display(size: 16.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.center)
            }
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().overlay(Color.Bandito.line) }
                        AccountServerLine(row: row)
                            .padding(.vertical, BanditoSpace.s3)
                    }
                }
                .padding(.horizontal, BanditoSpace.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.Bandito.surface1))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
            }
            Spacer()
            Button(action: onConnect) {
                HStack(spacing: BanditoSpace.s2) {
                    Circle()
                        .fill(Color.Bandito.signalFill)
                        .frame(width: 7, height: 7)
                    Text(L10n.Empty.NoServers.action)
                }
            }
            .buttonStyle(SignalButtonStyle())
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .accessibilityIdentifier("crew.accountServers")
    }
}
