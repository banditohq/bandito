import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// What `.sheet(item:)` opens: one value is one sheet, with a fresh scanner.
struct JoinScanRequest: Identifiable {
    let id = UUID()
}

/// What the scanner does with a text it read: a sign-in code, something else, or nothing yet.
enum JoinScanReading: Equatable {
    case ticket
    case notJoin
}

extension JoinScanReading {
    /// A Bandito pairing code or any other QR code is "not a sign-in code".
    static func of(_ text: String) -> JoinScanReading {
        JoinTicket.find(in: text) != nil ? .ticket : .notJoin
    }
}

/// «Войти с помощью Mac»: the camera that reads the code on the Mac. The first sign-in code closes the sheet and hands
/// its ticket on. On the Simulator (no camera) a debug build has a field to paste the link.
struct JoinScannerSheet: View {
    let onTicket: @MainActor (JoinTicket) -> Void
    let onClose: () -> Void

    /// The code was handed on: the camera sees it many times a second, and it is used once.
    @State private var handled = false
    @State private var notJoin = false
    @State private var lastIgnored: Date?
    #if DEBUG
    @State private var pasted = ""
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BanditoSpace.s5) {
                    VStack(spacing: BanditoSpace.s2) {
                        Text(L10n.Ios.Join.Scan.title)
                            .font(BanditoFont.display(size: 20, weight: 700))
                            .foregroundStyle(Color.Bandito.text)
                            .multilineTextAlignment(.center)
                        Text(L10n.Ios.Join.Scan.hint)
                            .font(BanditoFont.text(size: 14))
                            .foregroundStyle(Color.Bandito.text2)
                            .multilineTextAlignment(.center)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    ScannerBox { read($0, scanned: true) }
                    if notJoin {
                        Text(L10n.Ios.Join.Scan.notJoin)
                            .font(BanditoFont.text(size: 13))
                            .foregroundStyle(Color.Bandito.danger)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("join.notJoin")
                    }
                    #if DEBUG
                    pasteField
                    #endif
                }
                .padding(BanditoSpace.s5)
            }
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(L10n.Ios.Join.button)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.close, action: onClose).accessibilityIdentifier("join.close")
                }
            }
        }
    }

    /// One text from the camera, or from the field. A sign-in code is used once; another code is said once, not at camera speed.
    private func read(_ text: String, scanned: Bool) {
        guard !handled else { return }
        switch JoinScanReading.of(text) {
        case .ticket:
            guard let ticket = JoinTicket.find(in: text) else { return }
            handled = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onTicket(ticket)
        case .notJoin:
            if scanned, let last = lastIgnored, Date().timeIntervalSince(last) < 3 { return }
            lastIgnored = Date()
            notJoin = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    #if DEBUG
    /// The Simulator has no camera: the link of the code is pasted here.
    private var pasteField: some View {
        VStack(spacing: BanditoSpace.s3) {
            TextField(L10n.Ios.Join.Paste.placeholder, text: $pasted)
                .font(BanditoFont.mono(size: 13))
                .foregroundStyle(Color.Bandito.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(BanditoSpace.s3)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
                .accessibilityIdentifier("join.paste.field")
            Button(L10n.Ios.Join.Paste.submit) { read(pasted, scanned: false) }
                .buttonStyle(QuietButtonStyle())
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("join.paste.submit")
        }
    }
    #endif
}
