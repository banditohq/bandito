import BanditoDesign
import BanditoL10n
import SwiftUI

/// A small sheet asking for the name of a new folder or file.
struct FileNameSheet: View {
    let sheet: NameSheet
    let existing: Set<String>
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    /// Names with a slash or the dot names would point elsewhere; a taken name would fail on the server.
    private var isValid: Bool {
        !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".." && !existing.contains(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sheet == .folder ? L10n.Files.Dialog.newFolder : L10n.Files.Dialog.newFile)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            TextField(L10n.Files.Dialog.name, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.Bandito.text.opacity(0.1)))
                .onSubmit(submit)
            if existing.contains(trimmed) {
                Text(L10n.Files.Error.exists)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.danger)
            }
            HStack {
                Spacer()
                Button(L10n.Files.cancel) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Button(L10n.Files.Dialog.create, action: submit)
                    .buttonStyle(SignalButtonStyle())
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Color.Bandito.surface2)
    }

    private func submit() {
        guard isValid else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
