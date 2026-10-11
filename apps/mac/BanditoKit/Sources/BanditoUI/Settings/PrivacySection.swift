import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Privacy: anonymous statistics, crash reports, deleting the data sent so far, and the policy.
struct PrivacySection: View {
    @Environment(TelemetryCenter.self) private var telemetry
    @Environment(\.openURL) private var openURL
    @State private var confirmingDelete = false
    @State private var deleteFailed = false

    var body: some View {
        SettingsPage(title: SettingsSection.privacy.title, intro: L10n.Settings.Privacy.intro) {
            SettingsGroup {
                SettingsRow(
                    title: L10n.Settings.Privacy.stats, hint: L10n.Settings.Privacy.statsHint,
                    icon: SettingsIcon(symbol: "chart.bar", tint: BanditoPalette.badgeBlue),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: statsBinding)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.Privacy.crashes, hint: L10n.Settings.Privacy.crashesHint,
                    icon: SettingsIcon(symbol: "exclamationmark.triangle", tint: BanditoPalette.badgeOrange),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: crashBinding)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
            }
            SettingsGroup {
                SettingsRow(
                    title: L10n.Settings.Privacy.delete, hint: L10n.Settings.Privacy.deleteHint,
                    icon: SettingsIcon(symbol: "trash", tint: BanditoPalette.badgeRed)
                ) {
                    Button(L10n.Settings.Privacy.delete) { confirmingDelete = true }
                        .banditoButton(.quiet(tone: .danger))
                }
                if deleteFailed {
                    Text(L10n.Settings.Privacy.deleteFailed)
                        .font(BanditoFont.text(size: 12))
                        .foregroundStyle(Color.Bandito.danger)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
            SettingsGroup {
                SettingsRow(
                    title: L10n.Telemetry.Notice.policy,
                    icon: SettingsIcon(symbol: "hand.raised", tint: BanditoPalette.badgeDarkGray)
                ) {
                    // The row's title already says what this is; the control is only the way to the page.
                    Button { openURL(TelemetryCenter.privacyPolicyURL) } label: { Image(systemName: "arrow.up.right") }
                        .banditoButton(.icon(size: 28, label: L10n.Telemetry.Notice.policy))
                }
            }
        }
        .sheet(isPresented: $confirmingDelete) {
            TelemetryConfirmSheet(
                title: L10n.Settings.Privacy.deleteTitle,
                message: L10n.Settings.Privacy.deleteBody,
                confirmTitle: L10n.Common.delete,
                confirmIsDanger: true,
                onConfirm: { confirmingDelete = false; deleteData() },
                onCancel: { confirmingDelete = false })
        }
    }

    private var statsBinding: Binding<Bool> {
        Binding(get: { telemetry.statsEnabled }, set: { telemetry.setStatistics($0) })
    }

    private var crashBinding: Binding<Bool> {
        Binding(get: { telemetry.crashReports }, set: { telemetry.setCrashReports($0) })
    }

    private func deleteData() {
        deleteFailed = false
        Task {
            do {
                try await telemetry.deleteData()
            } catch {
                deleteFailed = true
            }
        }
    }
}
